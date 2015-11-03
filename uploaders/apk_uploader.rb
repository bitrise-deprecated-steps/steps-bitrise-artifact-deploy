require 'json'
require 'ipa_analyzer'

# -----------------------
# --- upload ipa
# -----------------------

def deploy_apk_to_bitrise(apk_path, build_url, api_token, notify_user_groups, notify_emails, is_enable_public_page)
  puts
  puts "# Deploying ipa file: #{apk_path}"

  apk_file_size = File.size(apk_path)
  puts "  (i) apk_file_size: #{apk_file_size} KB / #{apk_file_size / 1024.0} MB"

  # - Create a Build Artifact on Bitrise
  puts
  puts '=> Create a Build Artifact on Bitrise'
  upload_url, artifact_id = create_artifact(build_url, api_token, apk_path, 'android-apk')
  fail 'No upload_url provided for the artifact' if upload_url.nil?
  fail 'No artifact_id provided for the artifact' if artifact_id.nil?

  # - Upload the IPA
  puts
  puts '=> Upload the ipa'
  upload_file(upload_url, apk_path)

  # - Finish the Artifact creation
  puts
  puts '=> Finish the Artifact creation'
  finish_artifact(build_url,
                  api_token,
                  artifact_id,
                  JSON.dump(ipa_info_hsh),
                  notify_user_groups,
                  notify_emails,
                  is_enable_public_page
                 )
end
