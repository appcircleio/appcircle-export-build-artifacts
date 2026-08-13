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

# Human readable byte count, e.g. 1000000 -> "1.0 MB".
# Decimal (1000-based) units, matching how chunkSize and the server report sizes.
def format_bytes(bytes)
  units = %w[B KB MB GB TB]
  value = bytes.to_f
  index = 0
  while value >= 1000 && index < units.length - 1
    value /= 1000
    index += 1
  end
  index.zero? ? "#{bytes} B" : "#{value.round(2)} #{units[index]}"
end

# Human readable duration, e.g. 0.41 -> "410ms", 92.3 -> "1m 32s"
def format_duration(seconds)
  return "#{(seconds * 1000).round}ms" if seconds < 1
  return "#{seconds.round(2)}s" if seconds < 60
  minutes, secs = seconds.divmod(60)
  "#{minutes.to_i}m #{secs.round}s"
end

def format_speed(bytes, seconds)
  return "-" if seconds <= 0
  "#{(bytes / seconds / 1_000_000.0).round(2)} MB/s"
end

def utc_timestamp
  Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
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

SEPARATOR_WIDTH = 120
MAX_UPLOAD_ATTEMPTS = 3

# Tracks the file being uploaded so an unexpected failure can name it in the banner below.
$currentFile = nil

# Any unhandled error still aborts the step with a non-zero exit and a backtrace, but print a
# clear FAILED banner first so the outcome is obvious at the end of the log.
at_exit do
    error = $!
    if error && !error.is_a?(SystemExit)
        puts ""
        puts "=" * SEPARATOR_WIDTH
        puts "EXPORT BUILD ARTIFACTS FAILED - #{utc_timestamp}"
        puts "  file   : #{$currentFile}" if $currentFile
        puts "  reason : #{error.message}"
        puts "=" * SEPARATOR_WIDTH
    end
end

uploadDir = ENV["AC_UPLOAD_DIR"];
urlChunk = URI(ENV["AC_UPLOADCHUNK_URL"])
urlComplete = URI(ENV["AC_COMPLETEUPLOAD_URL"])
chunkSize = 100000000 #100MB

puts "=" * SEPARATOR_WIDTH
puts "EXPORT BUILD ARTIFACTS"
puts "=" * SEPARATOR_WIDTH
puts "  chunk upload url    : #{ENV["AC_UPLOADCHUNK_URL"]}"
puts "  complete upload url : #{ENV["AC_COMPLETEUPLOAD_URL"]}"
puts "  upload dir          : #{uploadDir}"
puts "  chunk size          : #{format_bytes(chunkSize)}"
puts "  max attempts/chunk  : #{MAX_UPLOAD_ATTEMPTS}"
puts "  started at          : #{utc_timestamp}"
puts "=" * SEPARATOR_WIDTH

if should_delete_artifacts?
    if File.file?(uploadDir)
        File.delete(entry)
    else
        delete_files_and_directories(uploadDir)
    end
end

puts ""
puts "DISCOVERING FILES"
puts "-" * SEPARATOR_WIDTH

if File.file?(uploadDir)
    puts "  upload path is a file"
    filesList = []
    filesList.push(uploadDir)
else
    puts "  upload path is a directory"
    Dir.glob(uploadDir+'/*').each do |file|
       if File.directory?(file)
          puts "  zipping directory: #{file}"
          `zip -r "#{file}.zip" "#{file}"`
       end
    end

    filesList = Dir.glob(uploadDir+'/*').select { |e| File.file? e }
end

fileIndex = 0    # counter for unique temp chunk filenames (ac_chunk_N); bumped per chunk written
artifactIndex = 0  # counter for requestName numbering (artifact1, artifact2, ...); bumped once per uploaded (non-log) file
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

totalFiles = filesList.length
fileNo = 0
skippedFiles = 0
uploadedBytesTotal = 0
uploadStartedAt = Time.now

puts "  found #{totalFiles} file(s) to upload"

filesList.each do |f|
    fileNo += 1
    filePrefix = "[file #{fileNo}/#{totalFiles}]"
    $currentFile = File.basename(f)

    puts ""
    puts "-" * SEPARATOR_WIDTH
    puts "#{filePrefix} #{File.basename(f)}"
    puts "-" * SEPARATOR_WIDTH

    if !File.exist?(f)
        puts "  SKIPPED : file does not exist (#{f})"
        skippedFiles += 1
        fileIndex += 1
        next
    end

    size = File.size(f)
    if size == 0
        puts "  SKIPPED : file size is 0 byte (#{f})"
        skippedFiles += 1
        fileIndex += 1
        next
    end

    filename = File.basename(f)
    totalChunks = (size.to_f / chunkSize).ceil

    puts "  path    : #{f}"
    puts "  size    : #{format_bytes(size)} (#{size} bytes) -> #{totalChunks} chunk(s) of #{format_bytes(chunkSize)}"

    # Calculate SHA256 hash for file integrity validation
    hashStartedAt = Time.now
    file_hash = compute_file_sha256(f)
    puts "  sha256  : #{file_hash} (computed in #{format_duration(Time.now - hashStartedAt)})"

    # Store hash and file info for table logging
    file_info_table.push({
        name: filename,
        size: size,
        hash: file_hash
    })

    if f != logFileSnapshot
        artifactIndex += 1
        requestName = "artifact#{artifactIndex}"
        files.push({key: requestName, value: filename})
        file_hashes[filename] = file_hash  # Store hash by filename
    else
        STDOUT.flush
        sleep(10)

        FileUtils.cp logFile, logFileSnapshot
        sectionEnd = "\r\n@@[section:end] Step completed " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
        File.open(logFileSnapshot, "a"){|f| f.write(sectionEnd)}

        requestName = "log"
        files.push({key: "log", value: "log.txt"})
        file_hashes["log.txt"] = file_hash  # Store log hash
    end

    puts "  target  : #{requestName}"
    puts ""

    offset = 0
    chunkNo = 0
    fileUploadStartedAt = Time.now

    File.open(f, 'rb') do |file|
        while chunk = file.read(chunkSize)
            chunkNo += 1

            File.open("ac_chunk_#{(fileIndex + 1)}", 'wb') do |fo|
                fo.write(chunk)
            end

            fileSize = File.size("ac_chunk_#{(fileIndex + 1)}")

            http = Net::HTTP.new(urlChunk.host, urlChunk.port)
            http.read_timeout = 600
            http.use_ssl = true if urlChunk.instance_of? URI::HTTPS
            # Per-chunk SHA256 (uppercase hex, same convention as compute_file_sha256 / C# HashHelper)
            # so the server can verify the received bytes and return 500 on transit corruption, which
            # triggers the Retriable retry below with a fresh body.
            chunk_hash = Digest::SHA256.hexdigest(chunk).upcase

            # Right-align the chunk number against the total so the columns stay
            # aligned across every chunk of the file, without a fixed-width gap.
            chunkLabel = "chunk #{chunkNo.to_s.rjust(totalChunks.to_s.length)}/#{totalChunks}"
            chunkInfo = sprintf("%-14s  offset %10s  size %10s", chunkLabel, format_bytes(offset), format_bytes(fileSize))

            attempt = 0
            # Build the request and (re)open the chunk file INSIDE the retry block so every
            # attempt streams a fresh multipart body from position 0. Reusing one request object
            # across retries re-sends an already-consumed (EOF) file stream, which uploads an
            # empty/truncated chunk and corrupts the reassembled artifact.
            Retriable.retriable(tries: MAX_UPLOAD_ATTEMPTS) do
                attempt += 1
                attemptLabel = sprintf("attempt %d/%d", attempt, MAX_UPLOAD_ATTEMPTS)
                attemptStartedAt = Time.now

                begin
                    File.open("ac_chunk_#{(fileIndex + 1)}") do |chunk_io|
                        request = Net::HTTP::Post.new(urlChunk)
                        request["Content-Type"] = "application/json"
                        form_data = [['agentId', agentId],
                                ['queueId', queueId],
                                ['fileSize', fileSize.to_s],
                                ['name', requestName],
                                ['filename', File.basename(f)],
                                ['offset', offset.to_s],
                                ['chunkHash', chunk_hash],
                                ['chunk', chunk_io]]
                        request.set_form form_data, 'multipart/form-data'
                        response = http.request(request)
                        unless response.is_a?(Net::HTTPSuccess)
                            raise "HTTP #{response.code} #{response.body.to_s.strip[0, 200]}"
                        end
                    end
                    elapsed = Time.now - attemptStartedAt
                    puts sprintf("    %s  %s  SUCCESS  in %8s  %s", chunkInfo, attemptLabel, format_duration(elapsed), format_speed(fileSize, elapsed))
                rescue => e
                    elapsed = Time.now - attemptStartedAt
                    remaining = MAX_UPLOAD_ATTEMPTS - attempt
                    followUp = remaining > 0 ? "retrying (#{remaining} attempt(s) left)" : "no attempts left, giving up"
                    puts sprintf("    %s  %s  FAILED   in %8s  %s -> %s", chunkInfo, attemptLabel, format_duration(elapsed), e.message, followUp)
                    raise
                end
            end

            offset += fileSize
            fileIndex += 1
        end
    end

    fileElapsed = Time.now - fileUploadStartedAt
    uploadedBytesTotal += offset
    puts ""
    puts "  result  : SUCCESS - #{format_bytes(offset)} in #{chunkNo} chunk(s), took #{format_duration(fileElapsed)} (avg #{format_speed(offset, fileElapsed)})"
end

$currentFile = nil

# Display artifact hash summary table
if !file_info_table.empty?
    puts ""
    puts "=" * SEPARATOR_WIDTH
    puts "ARTIFACT HASH SUMMARY (SHA256)"
    puts "=" * SEPARATOR_WIDTH
    puts sprintf("  %-40s  %12s  %s", "File Name", "Size", "SHA256 Hash")
    puts "-" * SEPARATOR_WIDTH

    file_info_table.each do |info|
        display_name = info[:name].length > 40 ? info[:name][0..36] + "..." : info[:name]
        puts sprintf("  %-40s  %12s  %s", display_name, format_bytes(info[:size]), info[:hash])
    end

    puts "-" * SEPARATOR_WIDTH
    puts "  uploaded : #{file_info_table.length} file(s), #{format_bytes(uploadedBytesTotal)}"
    puts "  skipped  : #{skippedFiles} file(s)"
    puts "  duration : #{format_duration(Time.now - uploadStartedAt)}"
    puts "=" * SEPARATOR_WIDTH
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

puts ""
puts "COMPLETING UPLOAD"
puts "-" * SEPARATOR_WIDTH
puts "  files       : #{files.length}"
puts "  file hashes : #{file_hashes.length}"
puts "  is success  : #{isSuccess}"
puts ""

request.body = bodyJson
completeAttempt = 0
Retriable.retriable(tries: MAX_UPLOAD_ATTEMPTS) do
    completeAttempt += 1
    attemptLabel = sprintf("attempt %d/%d", completeAttempt, MAX_UPLOAD_ATTEMPTS)
    attemptStartedAt = Time.now
    begin
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
            raise "HTTP #{response.code} #{response.body.to_s.strip[0, 200]}"
        end
        puts sprintf("    complete upload  %s  SUCCESS  in %8s", attemptLabel, format_duration(Time.now - attemptStartedAt))
    rescue => e
        remaining = MAX_UPLOAD_ATTEMPTS - completeAttempt
        followUp = remaining > 0 ? "retrying (#{remaining} attempt(s) left)" : "no attempts left, giving up"
        puts sprintf("    complete upload  %s  FAILED   in %8s  %s -> %s", attemptLabel, format_duration(Time.now - attemptStartedAt), e.message, followUp)
        raise
    end
end

puts ""
puts "=" * SEPARATOR_WIDTH
puts "EXPORT BUILD ARTIFACTS COMPLETED - #{utc_timestamp}"
puts "=" * SEPARATOR_WIDTH
