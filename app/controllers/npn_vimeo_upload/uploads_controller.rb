# frozen_string_literal: true

module ::NpnVimeoUpload
  class UploadsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

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

      name = params[:name].to_s.strip.presence || "Untitled"

      result =
        vimeo.create_upload(
          size: size,
          name: name.truncate(128),
          description: "Uploaded by @#{current_user.username}",
          view: SiteSetting.npn_vimeo_upload_view_privacy,
          embed: SiteSetting.npn_vimeo_upload_embed_privacy,
        )

      uri = result["uri"].to_s
      # Unlisted videos come back as "/videos/123:abcdef".
      video_id = uri[%r{\A/videos/(\d+)(?::\w+)?\z}, 1]
      upload_link = result.dig("upload", "upload_link")

      if video_id.blank? || upload_link.blank?
        return render_json_error(I18n.t("npn_vimeo_upload.errors.vimeo_unreachable"), status: 502)
      end

      PluginStore.set(
        PLUGIN_NAME,
        "#{STORE_KEY_PREFIX}#{video_id}",
        { "user_id" => current_user.id, "created_at" => Time.zone.now.iso8601 },
      )

      allow_embed_domains(video_id) if SiteSetting.npn_vimeo_upload_embed_privacy == "whitelist"

      render json: { id: video_id, uri: uri, link: result["link"], upload_link: upload_link }
    rescue VimeoApi::Error => e
      render_vimeo_error(e)
    end

    def show
      find_owned_record!
      result = vimeo.video(params[:video_id])
      render json: {
               uri: result["uri"],
               link: result["link"],
               transcode_status: processing_status(result),
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

    VIDEO_FAILED_STATUSES = %w[
      uploading_error
      transcoding_error
      quota_exceeded
      total_cap_exceeded
    ].freeze

    # "complete", "error", or "in_progress". Uses the video's overall status
    # as well as transcode.status, since the latter can be missing.
    def processing_status(result)
      return "error" if VIDEO_FAILED_STATUSES.include?(result["status"])
      return "complete" if result["status"] == "available"
      transcode = result.dig("transcode", "status")
      return transcode if %w[complete error].include?(transcode)
      "in_progress"
    end

    def embed_domains
      domains = SiteSetting.npn_vimeo_upload_embed_domains.split("|").map(&:strip).reject(&:blank?)
      domains.presence || [Discourse.current_hostname]
    end

    # A failure here doesn't stop the upload; it's logged so an admin can fix
    # the domain list (or the token's "edit" scope) and re-save on Vimeo.
    def allow_embed_domains(video_id)
      embed_domains.each do |domain|
        vimeo.allow_embed_domain(video_id, domain)
      rescue VimeoApi::Error => e
        Rails.logger.warn(
          "[npn-vimeo-upload] Could not allow embedding of video #{video_id} on #{domain}: #{e.status} #{e.message}",
        )
      end
    end

    def ensure_allowed
      raise Discourse::InvalidAccess unless current_user.can_upload_to_npn_vimeo?
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
        # Vimeo's own message is in the log above; members get a plain one.
        render_json_error(I18n.t("npn_vimeo_upload.errors.vimeo_failed"), status: 422)
      end
    end
  end
end
