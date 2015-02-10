require 'json'
require 'net/http'
require 'uri'
require 'zip'
require 'tempfile'


# ----------------------------
# --- Options

options = {
	build_url: ENV['STEP_BITRISE_ARTIFACT_DEPLOY_BUILD_URL'],
	api_token: ENV['STEP_BITRISE_ARTIFACT_DEPLOY_API_TOKEN'],
	deploy_source_path: ENV['STEP_BITRISE_ARTIFACT_DEPLOY_SOURCE_PATH'],
	is_compress: false,
}
if ENV['STEP_BITRISE_ARTIFACT_IS_COMPRESS'] == 'true'
	options[:is_compress] = true
end

puts "Options: #{options}"


# ----------------------------
# --- Formatted Output

$formatted_output_file_path = ENV['STEPLIB_FORMATTED_OUTPUT_FILE_PATH']

def puts_string_to_formatted_output(text)
	puts text

	unless $formatted_output_file_path.nil?
		open($formatted_output_file_path, 'a') { |f|
			f.puts(text)
		}
	end
end

def puts_section_to_formatted_output(section_text)
	puts
	puts section_text
	puts

	unless $formatted_output_file_path.nil?
		open($formatted_output_file_path, 'a') { |f|
			f.puts
			f.puts(section_text)
			f.puts
		}
	end
end


# ----------------------------
# --- Cleanup

def cleanup_before_error_exit(reason_msg=nil)
	puts " [!] Error: #{reason_msg}"
	puts_section_to_formatted_output("## Failed")
	unless reason_msg.nil?
		puts_section_to_formatted_output(reason_msg)
	end
	puts_section_to_formatted_output("Check the Logs for details.")
end


# ----------------------------
# --- Utils

class ZipFileGenerator

	# Initialize with the directory to zip and the location of the output archive.
	def initialize(inputDir, outputFile)
		@inputDir = inputDir
		@outputFile = outputFile
	end

	# Zip the input directory.
	def write()
		entries = Dir.entries(@inputDir); entries.delete("."); entries.delete("..")
		io = Zip::File.open(@outputFile, Zip::File::CREATE);

		writeEntries(entries, "", io)
		io.close();
	end

	# A helper method to make the recursion work.
	private
	def writeEntries(entries, path, io)
		entries.each { |e|
			zipFilePath = path == "" ? e : File.join(path, e)
			diskFilePath = File.join(@inputDir, zipFilePath)
			puts " * Deflating " + diskFilePath
			if File.directory?(diskFilePath)
				io.mkdir(zipFilePath)
				subdir = Dir.entries(diskFilePath); subdir.delete("."); subdir.delete("..")
				writeEntries(subdir, zipFilePath, io)
			else
				io.get_output_stream(zipFilePath) { |f| f.puts(File.open(diskFilePath, "rb").read())}
			end
		}
	end

end

def deploy_file_to_bitrise(file_to_deploy_path, build_url, api_token)
	puts_section_to_formatted_output "Deploying file: `#{file_to_deploy_path}`"

	# - Create a Build Artifact on Bitrise
	file_to_deploy_filename = File.basename(file_to_deploy_path)

	uri = URI("#{build_url}/artifacts.json")
	raw_resp = Net::HTTP.post_form(uri, {
		'api_token' => api_token,
		'title' => file_to_deploy_filename,
		'filename' => file_to_deploy_filename,
		'artifact_type' => 'file'
		})
	puts "* raw_resp: #{raw_resp}"
	unless raw_resp.code == '200'
		raise "Failed to create the Build Artifact on Bitrise - code: #{raw_resp.code}"
	end
	parsed_resp = JSON.parse(raw_resp.body)
	puts "* parsed_resp: #{parsed_resp}"
	
	unless parsed_resp['error_msg'].nil?
		raise "Failed to create the Build Artifact on Bitrise: #{parsed_resp['error_msg']}"
	end

	upload_url = parsed_resp['upload_url']
	raise "No upload_url provided for the artifact" if upload_url.nil?
	artifact_id = parsed_resp['id']
	raise "No artifact_id provided for the artifact" if artifact_id.nil?

	# - Upload the IPA
	puts "* upload_url: #{upload_url}"

	unless system("curl --fail --silent -T '#{file_to_deploy_path}' -X PUT '#{upload_url}'")
		raise "Failed to upload the Artifact file"
	end

	# - Finish the Artifact creation
	uri = URI("#{build_url}/artifacts/#{artifact_id}/finish_upload.json")
	puts "* uri: #{uri}"
	raw_resp = Net::HTTP.post_form(uri, {
		'api_token' => api_token
		})
	puts "* raw_resp: #{raw_resp}"
	unless raw_resp.code == '200'
		raise "Failed to send 'finished' to Bitrise - code: #{raw_resp.code}"
	end
	parsed_resp = JSON.parse(raw_resp.body)
	puts "* parsed_resp: #{parsed_resp}"
	unless parsed_resp['status'] == 'ok'
		raise "Failed to send 'finished' to Bitrise"
	end
end


# ----------------------------
# --- Main

begin
	# - Option checks
	raise "No Build URL provided" unless options[:build_url]
	raise "No Build API Token provided" unless options[:api_token]
	raise "No Deploy (source) path provided" unless options[:deploy_source_path]

	if !Dir.exists?(options[:deploy_source_path]) and !File.exists?(options[:deploy_source_path])
		raise "Deploy source path does not exist at the provided path"
	end

	if File.directory?(options[:deploy_source_path])
		if options[:is_compress]
			puts_section_to_formatted_output("## Compressing the Deploy directory")
			tempfile = Tempfile.new(::File.basename(options[:deploy_source_path]))
			begin
				zip_archive_path = tempfile.path+".zip"
				puts " (i) zip_archive_path: #{zip_archive_path}"
				zip_gen = ZipFileGenerator.new(options[:deploy_source_path], zip_archive_path)
				zip_gen.write()
				tempfile.close

				raise "Failed to create compressed ZIP file" unless File.exists?(zip_archive_path)

				deploy_file_to_bitrise(
					zip_archive_path,
					options[:build_url],
					options[:api_token]
					)
			rescue => ex
				raise ex
			ensure
				tempfile.close
				tempfile.unlink
			end
		else
			puts_section_to_formatted_output("## Uploading the content of the Deploy directory separately")
			entries = Dir.entries(options[:deploy_source_path]); entries.delete("."); entries.delete("..")
			entries.each { |filepth|
				diskFilePath = File.join(options[:deploy_source_path], filepth)
				unless File.directory?(diskFilePath)
					deploy_file_to_bitrise(
						diskFilePath,
						options[:build_url],
						options[:api_token]
						)
				end
			}
		end
	else
		# Deploy source path is a single file
		deploy_file_to_bitrise(
			options[:deploy_source_path],
			options[:build_url],
			options[:api_token]
			)
	end

	# - Success
	puts_section_to_formatted_output("## Success")
	#
	puts_section_to_formatted_output("You can find the Artifact on Bitrise, on the [Build's page](#{options[:build_url]})")
rescue => ex
	cleanup_before_error_exit "#{ex}"
	exit 1
end

exit 0