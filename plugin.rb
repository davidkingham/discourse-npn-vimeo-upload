# frozen_string_literal: true

# name: discourse-npn-vimeo-upload
# about: Server-side Vimeo upload broker for NPN. Keeps the Vimeo access token on the server so members can upload to NPN's Vimeo account without the token ever reaching a browser. Used by the discourse-video-upload theme component (npn-server-vimeo branch).
# version: 0.1.0
# authors: David Kingham
# url: https://github.com/davidkingham/discourse-npn-vimeo-upload
# license: MIT

enabled_site_setting :npn_vimeo_upload_enabled

module ::NpnVimeoUpload
  PLUGIN_NAME = "discourse-npn-vimeo-upload"
end

require_relative "lib/npn_vimeo_upload/engine"

after_initialize { require_relative "lib/npn_vimeo_upload/vimeo_api" }
