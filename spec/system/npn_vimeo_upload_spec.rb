# frozen_string_literal: true

RSpec.describe "NPN Vimeo upload" do
  fab!(:group)
  fab!(:member) { Fabricate(:user, refresh_auto_groups: true).tap { |u| group.add(u) } }
  fab!(:outsider) { Fabricate(:user, refresh_auto_groups: true) }

  let(:composer) { PageObjects::Components::Composer.new }

  before do
    SiteSetting.npn_vimeo_upload_enabled = true
    SiteSetting.npn_vimeo_upload_access_token = "secret-vimeo-token"
    SiteSetting.npn_vimeo_upload_allowed_groups = group.id.to_s
  end

  it "shows the button to allowed members and opens the upload form" do
    sign_in(member)
    visit("/new-topic")

    expect(composer).to be_opened
    find("button.npn-vimeo-upload").click

    expect(page).to have_css(".npn-vimeo-upload-modal")
    expect(page).to have_css(".npn-vimeo-upload-submit")
    expect(page).to have_select("npn-vimeo-view-privacy", selected: "Public")
    expect(page.html).not_to include("secret-vimeo-token")
  end

  it "hides the button from members outside the allowed groups" do
    sign_in(outsider)
    visit("/new-topic")

    expect(composer).to be_opened
    expect(page).to have_no_css("button.npn-vimeo-upload")
    expect(page.html).not_to include("secret-vimeo-token")
  end
end
