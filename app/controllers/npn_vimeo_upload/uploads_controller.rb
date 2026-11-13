# frozen_string_literal: true

module ::NpnVimeoUpload
  class UploadsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    VIEW_PRIVACY = %w[anybody unlisted disable].freeze
    EMBED_PRIVACY = %w[public private].freeze
    STORE_KEY_PREFIX = "video:"
    DELETE_WINDOW = 1.day

    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_configured

    def create
      size = params.require(:size).to_i
      raise Discourse::InvalidParameters.new(:size) if size <= 0

      max_bytes = SiteSetting.npn_vimeo_upload_max_size_mb.megabytes
      if size > max_bytes
        return(
          render_json_error(
            I18n.t(
              "npn_vimeo_upload.errors.too_large",
              max_mb: SiteSetting.npn_vimeo_upload_max_size_mb,
            ),
            status: 422,
          )
        )
      end

      unless current_user.admin?
        RateLimiter.new(
          current_user,
          "npn_vimeo_upload",
          SiteSetting.npn_vimeo_upload_daily_limit,
          1.day,
        ).performed!
      end

      view = VIEW_PRIVACY.include?(params[:view_privacy]) ? params[:view_privacy] : "anybody"
      embed = EMBED_PRIVACY.include?(params[:embed_privacy]) ? params[:embed_privacy] : "public"
      name = params[:name].to_s.strip.presence || "Untitled"
      description = params[:description].to_s.strip

      result =
        vimeo.create_upload(
          size: size,
          name: name.truncate(128),
          description: "#{description.truncate(4000)}\nby @#{current_user.username}".strip,
          view: view,
          embed: embed,
        )

      uri = result["uri"].to_s
      video_id = uri[%r{\A/videos/(\d+)\z}, 1]
      upload_link = result.dig("upload", "upload_link")

      if video_id.blank? || upload_link.blank?
        return render_json_error(I18n.t("npn_vimeo_upload.errors.vimeo_unreachable"), status: 502)
      end

      PluginStore.set(
        PLUGIN_NAME,
        "#{STORE_KEY_PREFIX}#{video_id}",
        { "user_id" => current_user.id, "created_at" => Time.zone.now.iso8601 },
      )

      render json: { uri: uri, link: result["link"], upload_link: upload_link }
    rescue VimeoApi::Error => e
      render_vimeo_error(e)
    end

    def show
      find_owned_record!
      result = vimeo.video(params[:video_id])
      render json: {
               uri: result["uri"],
               link: result["link"],
               transcode_status: result.dig("transcode", "status"),
             }
    rescue VimeoApi::Error => e
      render_vimeo_error(e)
    end

    # Only used to clean up a cancelled upload, so it is limited to the
    # uploader's own videos made in the last day.
    def destroy
      record = find_owned_record!
      created_at =
        begin
          Time.zone.parse(record["created_at"].to_s)
        rescue StandardError
          nil
        end
      raise Discourse::InvalidAccess if created_at.nil? || created_at < DELETE_WINDOW.ago

      vimeo.delete_video(params[:video_id])
      PluginStore.remove(PLUGIN_NAME, "#{STORE_KEY_PREFIX}#{params[:video_id]}")
      render json: success_json
    rescue VimeoApi::Error => e
      render_vimeo_error(e)
    end

    private

    def vimeo
      @vimeo ||= VimeoApi.new
    end

    def ensure_allowed
      allowed = SiteSetting.npn_vimeo_upload_allowed_groups_map
      raise Discourse::InvalidAccess if allowed.empty? || !current_user.in_any_groups?(allowed)
    end

    def ensure_configured
      if SiteSetting.npn_vimeo_upload_access_token.blank?
        render_json_error(I18n.t("npn_vimeo_upload.errors.not_configured"), status: 503)
      end
    end

    def find_owned_record!
      record = PluginStore.get(PLUGIN_NAME, "#{STORE_KEY_PREFIX}#{params[:video_id]}")
      raise Discourse::NotFound if record.blank?
      raise Discourse::NotFound if record["user_id"] != current_user.id && !current_user.staff?
      record
    end

    def render_vimeo_error(error)
      Rails.logger.warn(
        "[npn-vimeo-upload] Vimeo #{error.status} for user #{current_user.id}: #{error.message}",
      )

      if error.status.to_i.zero? || error.status >= 500
        render_json_error(I18n.t("npn_vimeo_upload.errors.vimeo_unreachable"), status: 502)
      else
        # Vimeo's 4xx messages (e.g. privacy option not on this plan) are
        # useful to the member and never contain the token.
        render_json_error(
          I18n.t("npn_vimeo_upload.errors.vimeo_failed", message: error.message),
          status: 422,
          extras: {
            vimeo_error: error.body&.slice("error_code", "invalid_parameters"),
          },
        )
      end
    end
  end
end
