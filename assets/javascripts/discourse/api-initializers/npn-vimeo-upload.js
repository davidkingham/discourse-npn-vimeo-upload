import { apiInitializer } from "discourse/lib/api";
import NpnVimeoUpload from "../components/modal/npn-vimeo-upload";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.npn_vimeo_upload_enabled) {
    return;
  }

  const modal = api.container.lookup("service:modal");

  api.onToolbarCreate((toolbar) => {
    toolbar.addButton({
      id: "npn-vimeo-upload",
      // Own class so it can't pick up the upload form's .npn-vimeo-upload
      // styles (core uses the id as the class by default).
      className: "npn-vimeo-upload-button",
      group: "insertions",
      icon: "npn-video-upload",
      title: "npn_vimeo_upload.upload.video",
      perform: () => modal.show(NpnVimeoUpload),
      // Decided on the server from the allowed-groups setting; the server
      // also re-checks it on every upload request.
      condition: () => api.getCurrentUser()?.can_upload_to_npn_vimeo,
    });
  });
});
