# frozen_string_literal: true

RSpec.describe "NPN Vimeo upload" do
  fab!(:group)
  fab!(:member) { Fabricate(:user, refresh_auto_groups: true).tap { |u| group.add(u) } }
  fab!(:outsider) { Fabricate(:user, refresh_auto_groups: true) }

  let(:composer) { PageObjects::Components::Composer.new }
  let(:modal) { find(".npn-vimeo-upload-modal") }
  let(:submit_button) { find(".npn-vimeo-upload-submit") }

  before do
    SiteSetting.npn_vimeo_upload_enabled = true
    SiteSetting.npn_vimeo_upload_access_token = "secret-vimeo-token"
    SiteSetting.npn_vimeo_upload_allowed_groups = group.id.to_s
  end

  def open_upload_modal
    sign_in(member)
    visit("/new-topic")
    expect(composer).to be_opened
    find("button.npn-vimeo-upload-button").click
    expect(page).to have_css(".npn-vimeo-upload-modal")
  end

  # Simulates dragging files from the desktop and dropping them on the modal.
  def drop_files(*files)
    page.execute_script(<<~JS, files)
      const dt = new DataTransfer();
      for (const f of arguments[0]) {
        dt.items.add(new File([new Uint8Array(f.size)], f.name, { type: f.type }));
      }
      const target = document.querySelector(".npn-vimeo-upload-modal .d-modal__body");
      for (const type of ["dragenter", "dragover", "drop"]) {
        target.dispatchEvent(
          new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }),
        );
      }
    JS
  end

  it "shows a drop zone and nothing about Vimeo or privacy" do
    open_upload_modal

    expect(modal).to have_css(".npn-vimeo-upload__dropzone", text: "Drag a video here")
    expect(modal).to have_text("Up to 5 GB")
    expect(submit_button).to be_disabled
    expect(modal).to have_no_css("select")
    expect(modal).to have_no_text(/vimeo|privacy/i)
    expect(page.html).not_to include("secret-vimeo-token")
  end

  it "accepts a chosen file and fills in the title" do
    open_upload_modal

    file = Tempfile.new(%w[sunrise_over_aspens .mp4])
    file.write("fake video bytes")
    file.flush
    find(".npn-vimeo-upload__input", visible: :all).attach_file(file.path, make_visible: true)

    expect(modal).to have_css(".npn-vimeo-upload__file-name", text: File.basename(file.path))
    expect(modal).to have_field("npn-vimeo-title", with: /\Asunrise over aspens/)
    expect(submit_button).not_to be_disabled
  ensure
    file&.close!
  end

  it "accepts a dropped video, and can remove it again" do
    open_upload_modal
    drop_files({ name: "canyon_light.mov", type: "video/quicktime", size: 2048 })

    expect(modal).to have_css(".npn-vimeo-upload__file-name", text: "canyon_light.mov")
    expect(modal).to have_css(".npn-vimeo-upload__file-meta", text: "2 KB")
    expect(modal).to have_field("npn-vimeo-title", with: "canyon light")

    find(".npn-vimeo-upload__remove").click
    expect(modal).to have_css(".npn-vimeo-upload__dropzone")
    expect(modal).to have_no_field("npn-vimeo-title")
  end

  it "keeps a title the member typed when they swap the file" do
    open_upload_modal
    drop_files({ name: "first.mp4", type: "video/mp4", size: 10 })
    fill_in("npn-vimeo-title", with: "Morning at the lake")

    drop_files({ name: "second.mp4", type: "video/mp4", size: 10 })
    expect(modal).to have_css(".npn-vimeo-upload__file-name", text: "second.mp4")
    expect(modal).to have_field("npn-vimeo-title", with: "Morning at the lake")
  end

  it "explains files it can't take" do
    SiteSetting.npn_vimeo_upload_max_size_mb = 1
    open_upload_modal

    drop_files({ name: "notes.txt", type: "text/plain", size: 10 })
    expect(modal).to have_css(".npn-vimeo-upload__error", text: "That file isn't a video.")

    drop_files({ name: "huge.mp4", type: "video/mp4", size: 2 * 1024 * 1024 })
    expect(modal).to have_css(".npn-vimeo-upload__error", text: "The limit is 1 MB.")

    drop_files(
      { name: "a.mp4", type: "video/mp4", size: 10 },
      { name: "b.mp4", type: "video/mp4", size: 10 },
    )
    expect(modal).to have_css(".npn-vimeo-upload__error", text: "one video at a time")
    expect(modal).to have_css(".npn-vimeo-upload__dropzone")
  end

  it "hides the button from members outside the allowed groups" do
    sign_in(outsider)
    visit("/new-topic")

    expect(composer).to be_opened
    expect(page).to have_no_css("button.npn-vimeo-upload-button")
    expect(page.html).not_to include("secret-vimeo-token")
  end
end
