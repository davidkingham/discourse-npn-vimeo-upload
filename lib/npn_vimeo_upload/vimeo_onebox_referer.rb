# frozen_string_literal: true

module ::NpnVimeoUpload
  # Videos restricted to embedding on NPN's domain only return oEmbed data
  # when the request says it comes from that domain. Core's Vimeo onebox
  # sends no Referer, so those videos would show as a bare link instead of a
  # player. This sends the site's own URL as the Referer.
  #
  # Hidden ("Hide from Vimeo") videos also have no usable title or thumbnail
  # on their vimeo.com page, which the lazy-videos plugin reads, so fall back
  # to the oEmbed title and thumbnail.
  module VimeoOneboxReferer
    OgFallback = Struct.new(:title, :image)

    private

    def oembed_data
      @npn_oembed_data ||=
        begin
          response =
            Onebox::Helpers.fetch_response(
              "https://vimeo.com/api/oembed.json?url=#{url}",
              headers: {
                "Referer" => "#{Discourse.base_url}/",
              },
            )
          ::MultiJson.load(response, symbolize_keys: true)
        rescue StandardError
          {}
        end
    end

    def og_data
      @npn_og_data ||=
        begin
          og =
            begin
              super
            rescue StandardError
              nil
            end
          title = og&.title.presence || oembed_data[:title]
          image = og&.image.presence || oembed_data[:thumbnail_url]
          og && og.title.present? && og.image.present? ? og : OgFallback.new(title, image)
        end
    end
  end
end
