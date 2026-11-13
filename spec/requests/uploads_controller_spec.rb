# frozen_string_literal: true

RSpec.describe NpnVimeoUpload::UploadsController do
  fab!(:group)
  fab!(:member) { Fabricate(:user, refresh_auto_groups: true).tap { |u| group.add(u) } }
  fab!(:other_member) { Fabricate(:user, refresh_auto_groups: true).tap { |u| group.add(u) } }
  fab!(:outsider, :user)

  let(:token) { "secret-vimeo-token" }
  let(:upload_link) { "https://tus.vimeo.com/files/abc123" }

  before do
    SiteSetting.npn_vimeo_upload_enabled = true
    SiteSetting.npn_vimeo_upload_access_token = token
    SiteSetting.npn_vimeo_upload_allowed_groups = group.id.to_s
  end

  def stub_create(status: 200, body: nil)
    stub_request(:post, "https://api.vimeo.com/me/videos").with(
      headers: {
        "Authorization" => "Bearer #{token}",
      },
    ).to_return(
      status: status,
      body:
        (
          body ||
            {
              uri: "/videos/42",
              link: "https://vimeo.com/42",
              upload: {
                upload_link: upload_link,
              },
            }
        ).to_json,
    )
  end

  describe "POST /npn-vimeo/uploads" do
    it "requires login" do
      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(403)
    end

    it "rejects users outside the allowed groups" do
      sign_in(outsider)
      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(403)
    end

    it "rejects everyone when no groups are configured" do
      SiteSetting.npn_vimeo_upload_allowed_groups = ""
      sign_in(member)
      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(403)
    end

    it "creates the upload and never returns the token" do
      stub = stub_create
      sign_in(member)

      post "/npn-vimeo/uploads.json", params: { size: 100, name: "Aspens" }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq(
        "uri" => "/videos/42",
        "link" => "https://vimeo.com/42",
        "upload_link" => upload_link,
      )
      expect(response.body).not_to include(token)
      expect(
        stub.with do |req|
          body = JSON.parse(req.body)
          body["upload"] == { "approach" => "tus", "size" => 100 } && body["name"] == "Aspens" &&
            body["description"] == "Uploaded by @#{member.username}" &&
            body["privacy"] == { "view" => "anybody", "embed" => "public" }
        end,
      ).to have_been_requested
    end

    it "uses the admin privacy settings and ignores any sent by the browser" do
      SiteSetting.npn_vimeo_upload_view_privacy = "unlisted"
      SiteSetting.npn_vimeo_upload_embed_privacy = "private"
      stub = stub_create
      sign_in(member)
      post "/npn-vimeo/uploads.json",
           params: {
             size: 100,
             view_privacy: "password",
             embed_privacy: "whitelist",
           }

      expect(response.status).to eq(200)
      expect(
        stub.with do |req|
          JSON.parse(req.body)["privacy"] == { "view" => "unlisted", "embed" => "private" }
        end,
      ).to have_been_requested
    end

    it "enforces the size limit" do
      SiteSetting.npn_vimeo_upload_max_size_mb = 1
      sign_in(member)
      post "/npn-vimeo/uploads.json", params: { size: 2.megabytes }
      expect(response.status).to eq(422)
    end

    it "enforces the daily limit" do
      RateLimiter.enable
      SiteSetting.npn_vimeo_upload_daily_limit = 1
      stub_create
      sign_in(member)

      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(200)
      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(429)
    end

    it "gives members a plain message when Vimeo rejects the request" do
      stub_create(
        status: 400,
        body: {
          error: "bad",
          developer_message: "Privacy not allowed",
          error_code: 2410,
        },
      )
      sign_in(member)
      post "/npn-vimeo/uploads.json", params: { size: 100 }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("npn_vimeo_upload.errors.vimeo_failed"),
      )
      expect(response.body).not_to include("Privacy not allowed")
      expect(response.body).not_to include(token)
    end

    it "reports not configured without a token" do
      SiteSetting.npn_vimeo_upload_access_token = ""
      sign_in(member)
      post "/npn-vimeo/uploads.json", params: { size: 100 }
      expect(response.status).to eq(503)
    end
  end

  describe "status and delete" do
    before do
      stub_create
      sign_in(member)
      post "/npn-vimeo/uploads.json", params: { size: 100 }
    end

    it "returns transcode status to the uploader" do
      stub_request(:get, %r{https://api.vimeo.com/videos/42}).to_return(
        status: 200,
        body: {
          uri: "/videos/42",
          link: "https://vimeo.com/42",
          transcode: {
            status: "complete",
          },
        }.to_json,
      )
      get "/npn-vimeo/uploads/42.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["transcode_status"]).to eq("complete")
    end

    it "hides other members' videos" do
      sign_in(other_member)
      get "/npn-vimeo/uploads/42.json"
      expect(response.status).to eq(404)
      delete "/npn-vimeo/uploads/42.json"
      expect(response.status).to eq(404)
    end

    it "refuses videos it did not create" do
      get "/npn-vimeo/uploads/999.json"
      expect(response.status).to eq(404)
    end

    it "lets the uploader delete a fresh upload" do
      stub = stub_request(:delete, "https://api.vimeo.com/videos/42").to_return(status: 204)
      delete "/npn-vimeo/uploads/42.json"
      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
    end

    it "refuses to delete after a day" do
      freeze_time 2.days.from_now
      delete "/npn-vimeo/uploads/42.json"
      expect(response.status).to eq(403)
    end
  end
end
