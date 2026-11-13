# frozen_string_literal: true

module ::NpnVimeoUpload
  # Thin wrapper over the few Vimeo API calls the broker needs. The access
  # token only ever lives here, in the Authorization header of server-to-Vimeo
  # requests.
  class VimeoApi
    BASE_URL = "https://api.vimeo.com"
    ACCEPT = "application/vnd.vimeo.*+json;version=3.4"

    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    def initialize(token = SiteSetting.npn_vimeo_upload_access_token)
      raise ArgumentError, "missing Vimeo token" if token.blank?
      @token = token
    end

    # Creates the video and a tus upload session. The returned upload_link is
    # a per-video URL that accepts the file bytes without any token.
    def create_upload(size:, name:, description:, view:, embed:)
      request(
        :post,
        "/me/videos",
        body: {
          upload: {
            approach: "tus",
            size: size,
          },
          name: name,
          description: description,
          privacy: {
            view: view,
            embed: embed,
          },
        },
      )
    end

    def video(id)
      request(:get, "/videos/#{id}", query: { fields: "uri,link,status,transcode.status" })
    end

    # Lets the video be embedded on this domain when embed privacy is
    # "whitelist" (Vimeo's "specific domains" option).
    def allow_embed_domain(id, domain)
      request(:put, "/videos/#{id}/privacy/domains/#{ERB::Util.url_encode(domain)}")
    end

    def delete_video(id)
      request(:delete, "/videos/#{id}")
    end

    private

    def request(method, path, body: nil, query: nil)
      response =
        Excon.public_send(
          method,
          "#{BASE_URL}#{path}",
          query: query,
          body: body&.to_json,
          headers: {
            "Authorization" => "Bearer #{@token}",
            "Accept" => ACCEPT,
            "Content-Type" => "application/json",
          },
          connect_timeout: 10,
          read_timeout: 30,
          write_timeout: 30,
        )

      parsed =
        (
          if response.body.present?
            (
              begin
                JSON.parse(response.body)
              rescue StandardError
                {}
              end
            )
          else
            {}
          end
        )

      if response.status >= 400
        raise Error.new(
                parsed["developer_message"].presence || parsed["error"].presence ||
                  "HTTP #{response.status}",
                status: response.status,
                body: parsed,
              )
      end

      parsed
    rescue Excon::Error => e
      raise Error.new(e.class.name, status: 0)
    end
  end
end
