require "uri"
require "json"
require "net/http"
require 'fileutils'
require 'retriable'

$stdout.sync = true

puts "starting to upload files..."

puts ENV["AC_UPLOADCHUNK_URL"]
puts ENV["AC_COMPLETEUPLOAD_URL"]
puts "--------------------------------------"

uploadDir = ENV["AC_UPLOAD_DIR"];
urlChunk = URI(ENV["AC_UPLOADCHUNK_URL"])
urlComplete = URI(ENV["AC_COMPLETEUPLOAD_URL"])
chunkSize = 100000000 #100MB

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

chunkIndex = 0
fileIndex = 0
files = []

agentId = ENV['AC_AGENT_ID']==nil ? "00000000-0000-0000-0000-000000000000" : ENV['AC_AGENT_ID']
isSuccess = ENV['AC_IS_SUCCESS']==nil ? "true" : ENV['AC_IS_SUCCESS']
queueId = ENV['AC_QUEUE_ID']==nil ? "00000000-0000-0000-0000-000000000000" : ENV['AC_QUEUE_ID']
logFile = ENV['AC_LOGFILE']
if logFile != nil
    logFileSnapshot = logFile + '.snapshot'
    filesList.push(logFileSnapshot)
end

filesList.each do |f|
    puts "reading file: " + f + " " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
    
    if f != logFileSnapshot
        requestName = "artifact#{(fileIndex + 1)}"
        files.push({key: requestName, value: File.basename(f)})
    else
        STDOUT.flush
        sleep(10)

        FileUtils.cp logFile, logFileSnapshot
        sectionEnd = "\r\n@@[section:end] Step completed " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
        File.open(logFileSnapshot, "a"){|f| f.write(sectionEnd)}
        
        requestName = "log"
        files.push({key: "log", value: "log.txt"})
    end

    offset = 0	
    File.open(f, 'rb') do |file|	  
        while chunk = file.read(chunkSize)
            File.open("ac_chunk_#{(fileIndex + 1)}", 'wb') do |fo|
                fo.write(chunk)
            end
               	
            fileSize = File.size("ac_chunk_#{(fileIndex + 1)}")
               	
            http = Net::HTTP.new(urlChunk.host, urlChunk.port)
            http.read_timeout = 600
            http.use_ssl = true if urlChunk.instance_of? URI::HTTPS
            request = Net::HTTP::Post.new(urlChunk)
            request["Content-Type"] = "application/json"
            form_data = [['agentId', agentId],
                    ['queueId', queueId],
                    ['fileSize', fileSize.to_s],
                    ['name', requestName],
                    ['filename', File.basename(f)],
                    ['offset', offset.to_s],
                    ['chunk', File.open("ac_chunk_#{(fileIndex + 1)}")]]
                    	
            request.set_form form_data, 'multipart/form-data'
            Retriable.retriable do
                puts "  uploading... #{(fileIndex + 1)} #{requestName} #{offset.to_s} #{fileSize.to_s} "
                response = http.request(request)
            end
                       	
            offset += fileSize
            fileIndex += 1		
        end 
    end
end

http = Net::HTTP.new(urlComplete.host, urlComplete.port)
http.read_timeout = 600
http.use_ssl = true if urlComplete.instance_of? URI::HTTPS
request = Net::HTTP::Post.new(urlComplete)
request["Content-Type"] = "application/json"

bodyJson = { agentId: agentId, queueId: queueId, isSuccess: isSuccess, files: files }.to_json
request.body = bodyJson
Retriable.retriable do
    puts "Upload completing...  " + Time.now.utc.strftime("%m/%d/%Y %H:%M:%S")
    response = http.request(request)
end
