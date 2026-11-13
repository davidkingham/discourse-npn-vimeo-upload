# frozen_string_literal: true

# name: discourse-npn-vimeo-upload
# about: Lets NPN members upload videos from the composer to NPN's Vimeo account. The Vimeo token stays on the server; browsers only get a one-time upload link per video. Based on Arkshine's modernized discourse-video-upload theme component.
# version: 0.1.0
# authors: David Kingham
# url: https://github.com/davidkingham/discourse-npn-vimeo-upload
# license: MIT

enabled_site_setting :npn_vimeo_upload_enabled

module ::NpnVimeoUpload
  PLUGIN_NAME = "discourse-npn-vimeo-upload"
end

require_relative "lib/npn_vimeo_upload/engine"

register_asset "stylesheets/common/npn-vimeo-upload.scss"
register_svg_icon "fab-vimeo-v"
register_svg_icon "pause"
register_svg_icon "play"

after_initialize do
  require_relative "lib/npn_vimeo_upload/vimeo_api"

  add_to_class(:user, :can_upload_to_npn_vimeo?) do
    allowed = SiteSetting.npn_vimeo_upload_allowed_groups_map
    allowed.present? && in_any_groups?(allowed)
  end

  add_to_serializer(:current_user, :can_upload_to_npn_vimeo) { object.can_upload_to_npn_vimeo? }
end
