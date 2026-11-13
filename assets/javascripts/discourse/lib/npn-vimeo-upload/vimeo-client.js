import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import ResumableUploadClient from "./resumable-client";
import { CancelledError, sleep, UploadVideoError } from "./util";

// Uploads a video to NPN's Vimeo account.
//
// The server (this plugin) holds the Vimeo token. It creates the video and
// returns a per-video tus upload link, so the browser never sees the token.
// The file bytes go straight from the browser to Vimeo's upload link.
const BASE_PATH = "/npn-vimeo/uploads";

function toUploadError(error) {
  const wrapped = new Error(extractError(error));
  wrapped.status = error?.jqXHR?.status ?? error?.status ?? 0;
  return wrapped;
}

export default class VimeoUploadClient extends ResumableUploadClient {
  static defaults = {
    contentType: "application/offset+octet-stream",
  };

  constructor(options = {}) {
    super({ ...VimeoUploadClient.defaults, ...options });

    this.accept = "application/vnd.vimeo.*+json;version=3.4";
    this.videoUri = null;
    this.videoLink = null;
  }

  get videoId() {
    return this.videoUri?.split("/").pop();
  }

  getUploadMethod() {
    return "PATCH";
  }

  getUploadHeaders() {
    return {
      Accept: this.accept,
      "Tus-Resumable": "1.0.0",
      "Upload-Offset": String(this.offset),
      "Content-Type": this.contentType,
    };
  }

  async createUploadSession() {
    let response;

    try {
      response = await ajax(BASE_PATH, {
        type: "POST",
        data: {
          size: this.file.size,
          name: this.metadata.name,
          description: this.metadata.description,
          view_privacy: this.metadata.viewPrivacy,
          embed_privacy: this.metadata.embedPrivacy,
        },
      });
    } catch (error) {
      throw toUploadError(error);
    }

    this.url = response.upload_link;
    this.videoUri = response.uri;
    this.videoLink = response.link;

    if (!this.url) {
      throw new UploadVideoError(
        "errors.vimeo_upload_link_missing",
        "Missing Vimeo upload_link in response."
      );
    }
  }

  async resume() {
    try {
      const xhr = await this.xhr({
        method: "HEAD",
        url: this.url,
        headers: {
          Accept: this.accept,
          "Tus-Resumable": "1.0.0",
        },
      });

      const uploadOffset = xhr.getResponseHeader("Upload-Offset");
      if (uploadOffset != null) {
        this.offset = parseInt(uploadOffset, 10) || 0;
      }

      if (this.offset >= this.file.size) {
        return;
      }

      return await this.sendFile();
    } catch (error) {
      return await this.handleUploadError(error);
    }
  }

  async handleUploadSuccess(xhr) {
    if (xhr.status >= 200 && xhr.status < 300) {
      this.resetRetry();

      const uploadOffset = xhr.getResponseHeader("Upload-Offset");
      if (uploadOffset != null) {
        this.offset = parseInt(uploadOffset, 10) || 0;
      }

      if (this.offset < this.file.size) {
        return await this.sendFile();
      }

      return;
    }

    throw this.makeXHRError(
      xhr,
      "Vimeo upload failed.",
      "errors.vimeo_upload_failed"
    );
  }

  async transcodeStatus() {
    if (!this.videoId) {
      throw new UploadVideoError(
        "errors.vimeo_video_uri_missing",
        "No video URI available. Upload must complete first."
      );
    }

    try {
      const response = await ajax(`${BASE_PATH}/${this.videoId}`);
      this.videoLink = response.link ?? this.videoLink;
      return response.transcode_status;
    } catch (error) {
      throw toUploadError(error);
    }
  }

  async waitForTranscode({
    interval = 5000,
    timeout = 60 * 60 * 1000,
    shouldCancel = null,
  } = {}) {
    const startedAt = Date.now();

    while (true) {
      const status = await this.transcodeStatus();

      if (status === "complete") {
        return status;
      }

      if (status === "error") {
        throw new UploadVideoError(
          "errors.vimeo_transcoding_failed",
          "Vimeo transcoding failed."
        );
      }

      if (Date.now() - startedAt > timeout) {
        throw new UploadVideoError(
          "errors.vimeo_transcoding_timeout",
          "Timed out waiting for Vimeo transcoding."
        );
      }

      await sleep(interval);

      if (typeof shouldCancel === "function" && shouldCancel()) {
        throw new CancelledError();
      }
    }
  }

  getResult() {
    return this.videoUri;
  }

  async deleteVideo() {
    if (!this.videoId) {
      return;
    }

    await ajax(`${BASE_PATH}/${this.videoId}`, { type: "DELETE" });
  }
}
