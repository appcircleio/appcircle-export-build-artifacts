require "uri"
require "json"
require "net/http"
require 'fileutils'
require 'retriable'
require 'digest'

def compute_file_sha256(file_path)
  sha256 = Digest::SHA256.new
  File.open(file_path, 'rb') do |file|
    buffer = ''
    # Read in 4KB chunks (memory efficient)
    while file.read(4096, buffer)
      sha256.update(buffer)
    end
  end
  sha256.hexdigest.upcase  # Uppercase format to match C# implementation
end

CHUNK_UPLOAD_ATTEMPTS = 3

# Uploads a single chunk. The HTTP connection, the request and the chunk file handle are
# rebuilt on EVERY attempt: Net::HTTP serializes the multipart body from the file handle
# at send time, so a request object that was already sent holds a handle at EOF.
# Re-sending it uploads an empty chunk body, the server overwrites the stored chunk with
# 0 bytes, and the merged artifact is truncated and fails SHA256 validation.
def upload_chunk(url:, form_fields:, chunk_path:, label:)
  attempt = 0
  Retriable.retriable(tries: CHUNK_UPLOAD_ATTEMPTS) do
    attempt += 1
    puts "  uploading... #{label}#{attempt > 1 ? " (attempt #{attempt}/#{CHUNK_UPLOAD_ATTEMPTS})" : ''}"

    http = Net::HTTP.new(url.host, url.port)
    http.read_timeout = 600
    http.use_ssl = true if url.instance_of? URI::HTTPS

    File.open(chunk_path, 'rb') do |chunk_file|
      request = Net::HTTP::Post.new(url)
      request.set_form form_fields + [['chunk', chunk_file]], 'multipart/form-data'

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        puts "Error code from server: #{response.code}"
        puts response.body
        raise "Upload failed."
      end
    end
  end
end

def delete_files_and_directories(folder_path)
    Dir.glob("#{folder_path}/*").each do |entry|
      if File.directory?(entry)
        delete_files_and_directories(entry)
        Dir.rmdir(entry) if Dir.empty?(entry)
      else
        File.delete(entry)
      end
    end
end

def should_delete_artifacts?
    should_delete = ENV['AC_DISABLE_UPLOAD_ON_FAIL'] == 'true'
    is_success = ENV['AC_IS_SUCCESS']
    success = %w[true True].include?(is_success)
    should_delete && !success
end
    
$stdout.sync = true

puts "starting to upload files..."

puts ENV["AC_UPLOADCHUNK_URL"]
puts ENV["AC_COMPLETEUPLOAD_URL"]
puts "--------------------------------------"

uploadDir = ENV["AC_UPLOAD_DIR"];
urlChunk = URI(ENV["AC_UPLOADCHUNK_URL"])
urlComplete = URI(ENV["AC_COMPLETEUPLOAD_URL"])
chunkSize = 100000000 #100MB

if should_delete_artifacts?
    if File.file?(uploadDir)
        File.delete(uploadDir)
    else
        delete_files_and_directories(uploadDir)
    end
end

puts "uploading files...";

if File.file?(uploadDir)
    puts "upload path is file."
    filesList = []
    filesList.push(uploadDir)
else
    puts "upload path is directory."
    Dir.glob(uploadDir+'/*').each do |file|
       if File.directory?(file)
          puts "zipping directory: #{file}"
          `zip -r "#{file}.zip" "#{file}"`
       end
    end

    filesList = Dir.glob(uploadDir+'/*').select { |e| File.file? e }
end

fileIndex = 0
files = []
file_hashes = {}  # Hash storage for validation
file_info_table = []  # Table data for logging

agentId = ENV['AC_AGENT_ID']==nil ? "00000000-0000-0000-0000-000000000000" : ENV['AC_AGENT_ID']
isSuccess = ENV['AC_IS_SUCCESS']==nil ? "true" : ENV['AC_IS_SUCCESS']
queueId = ENV['AC_QUEUE_ID']==nil ? "00000000-0000-0000-0000-000000000000" : ENV['AC_QUEUE_ID']
logFile = ENV['AC_LOGFILE']
if logFile != nil
    logFileSnapshot = logFile + '.snapshot'
    filesList.push(logFileSnapshot)
end

filesList.each do |f|

    isLogSnapshot = logFileSnapshot != nil && f == logFileSnapshot

    # The log snapshot is produced here, so it must exist before the size / hash checks
    # below run. Appending the section-end marker also changes its content, so hashing it
    # any earlier would send the server a SHA256 of bytes that are never uploaded.
    if isLogSnapshot && File.exist?(logFile)
        STDOUT.flush
        sleep(10)

        FileUtils.cp logFile, logFileSnapshot
        sectionEnd = "\r\n@@[section:end] Step completed " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
        File.open(logFileSnapshot, "a"){|fo| fo.write(sectionEnd)}
    end

    if !File.exist?(f)
        puts "Skipping the file " + f + ". The file may not exist or its size is 0 byte" 
        fileIndex += 1	
        next
    end
    
    size = File.size(f)
    puts "reading file: " + f + " " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S") + " size:" + size.to_s + " bytes"
    if size == 0
        puts "Skipping the file " + f + " since its size is 0 byte!"
        fileIndex += 1
        next
    end

    # Calculate SHA256 hash for file integrity validation
    puts "Calculating SHA256 hash for: #{File.basename(f)}"
    start_time = Time.now
    file_hash = compute_file_sha256(f)
    elapsed = (Time.now - start_time).round(2)
    puts "  Hash calculated in #{elapsed}s: #{file_hash}"

    filename = File.basename(f)
    size_mb = (size / 1048576.0).round(2)

    # Store hash and file info for table logging
    file_info_table.push({
        name: filename,
        size_mb: size_mb,
        hash: file_hash
    })

    if !isLogSnapshot
        requestName = "artifact#{(fileIndex + 1)}"
        files.push({key: requestName, value: filename})
        file_hashes[filename] = file_hash  # Store hash by filename
    else
        requestName = "log"
        files.push({key: "log", value: "log.txt"})
        file_hashes["log.txt"] = file_hash  # Store log hash
    end

    offset = 0
    File.open(f, 'rb') do |file|
        while chunk = file.read(chunkSize)
            chunkPath = "ac_chunk_#{(fileIndex + 1)}"
            begin
                File.open(chunkPath, 'wb') do |fo|
                    fo.write(chunk)
                end

                fileSize = File.size(chunkPath)

                # The bytes about to be uploaded must match the bytes read from the source
                # file. A short temp file (no disk space, partial write) would otherwise be
                # uploaded as a valid chunk and corrupt the merged artifact silently.
                if fileSize != chunk.bytesize
                    raise "Chunk write failed for #{File.basename(f)} at offset #{offset}: expected #{chunk.bytesize} bytes but the temp file has #{fileSize} bytes."
                end

                form_fields = [['agentId', agentId],
                        ['queueId', queueId],
                        ['fileSize', fileSize.to_s],
                        ['name', requestName],
                        ['filename', File.basename(f)],
                        ['offset', offset.to_s]]

                start_time = Time.now
                upload_chunk(url: urlChunk,
                        form_fields: form_fields,
                        chunk_path: chunkPath,
                        label: "#{(fileIndex + 1)} #{requestName} #{offset.to_s} #{fileSize.to_s} ")
                end_time = Time.now
                upload_speed = fileSize.to_f / (end_time - start_time) / 1024 / 1024
                puts "  Upload speed: #{upload_speed.round(2)} MB/s"
                offset += fileSize
            ensure
                File.delete(chunkPath) if File.exist?(chunkPath)
            end
            fileIndex += 1
        end
    end
end

# Display artifact hash summary table
if !file_info_table.empty?
    puts ""
    puts "=" * 80
    puts "ARTIFACT HASH SUMMARY (SHA256)"
    puts "=" * 80

    # Header
    puts sprintf("%-40s %12s  %s", "File Name", "Size (MB)", "SHA256 Hash")
    puts "-" * 80

    # Each artifact row
    file_info_table.each do |info|
        display_name = info[:name].length > 40 ? info[:name][0..36] + "..." : info[:name]
        puts sprintf("%-40s %12.2f  %s", display_name, info[:size_mb], info[:hash])
    end

    puts "=" * 80
    puts "Total artifacts: #{file_info_table.length}"
    puts ""
end

http = Net::HTTP.new(urlComplete.host, urlComplete.port)
http.read_timeout = 600
http.use_ssl = true if urlComplete.instance_of? URI::HTTPS
request = Net::HTTP::Post.new(urlComplete)
request["Content-Type"] = "application/json"

bodyJson = {
    agentId: agentId,
    queueId: queueId,
    isSuccess: isSuccess,
    files: files,
    fileHashes: file_hashes  # Include file hashes for validation
}.to_json

puts "Sending complete upload request with #{file_hashes.length} file hashes"

request.body = bodyJson
Retriable.retriable do
    puts "Upload completing...  " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
        puts "Error code from server: #{response.code}"
        puts response.body
        raise "Upload completion failed."
    end
end
