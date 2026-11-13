# frozen_string_literal: true

RSpec.describe NpnVimeoUpload::VimeoOneboxReferer do
  let(:url) { "https://vimeo.com/42" }
  let(:oembed_url) { "https://vimeo.com/api/oembed.json?url=#{url}" }
  let(:oembed_body) do
    {
      type: "video",
      title: "Aspen Grove Sunrise",
      uri: "/videos/42",
      video_id: 42,
      thumbnail_url: "https://i.vimeocdn.com/video/42_640.jpg",
      html: '<iframe src="https://player.vimeo.com/video/42?app_id=1"></iframe>',
    }.to_json
  end

  before do
    # The vimeo.com page of a hidden video has no usable OpenGraph data.
    stub_request(:get, url).to_return(status: 200, body: "<html><head></head></html>")
    stub_request(:head, url).to_return(status: 200)
  end

  it "sends this site as the Referer so domain-restricted videos embed" do
    oembed =
      stub_request(:get, oembed_url).with(
        headers: {
          "Referer" => "#{Discourse.base_url}/",
        },
      ).to_return(status: 200, body: oembed_body)

    html = Onebox::Engine::VimeoOnebox.new(url).to_html

    expect(oembed).to have_been_requested.at_least_once
    expect(html).to include("42")
    expect(html).to match(%r{player\.vimeo\.com/video/42|data-video-id="42"})
  end

  it "uses the oEmbed title and thumbnail when the Vimeo page has none" do
    SiteSetting.lazy_videos_enabled = true
    SiteSetting.lazy_vimeo_enabled = true
    stub_request(:get, oembed_url).to_return(status: 200, body: oembed_body)

    html = Onebox::Engine::VimeoOnebox.new(url).to_html

    expect(html).to include('data-video-title="Aspen Grove Sunrise"')
    expect(html).to include("https://i.vimeocdn.com/video/42_640.jpg")
  end
end
