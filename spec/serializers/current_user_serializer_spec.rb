# frozen_string_literal: true

RSpec.describe CurrentUserSerializer do
  fab!(:group)
  fab!(:member) { Fabricate(:user).tap { |u| group.add(u) } }
  fab!(:outsider, :user)

  before do
    SiteSetting.npn_vimeo_upload_enabled = true
    SiteSetting.npn_vimeo_upload_allowed_groups = group.id.to_s
  end

  def serialized(user)
    described_class.new(user, scope: Guardian.new(user), root: false).as_json
  end

  it "flags members of an allowed group" do
    expect(serialized(member)[:can_upload_to_npn_vimeo]).to eq(true)
    expect(serialized(outsider)[:can_upload_to_npn_vimeo]).to eq(false)
  end

  it "allows no one when no groups are set" do
    SiteSetting.npn_vimeo_upload_allowed_groups = ""
    expect(serialized(member)[:can_upload_to_npn_vimeo]).to eq(false)
  end

  it "never includes the Vimeo token" do
    SiteSetting.npn_vimeo_upload_access_token = "secret-vimeo-token"
    expect(serialized(member).to_json).not_to include("secret-vimeo-token")
  end
end
