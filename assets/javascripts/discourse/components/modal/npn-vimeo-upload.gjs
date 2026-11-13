import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
// Old import paths kept on purpose: newer core shims them, older core only
// has these, so the plugin works on either.
/* eslint-disable discourse/ui-kit-imports */
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import concatClass from "discourse/helpers/concat-class";
import icon from "discourse/helpers/d-icon";
/* eslint-enable discourse/ui-kit-imports */
import { i18n } from "discourse-i18n";
import {
  CancelledError,
  uploadErrorMessage,
} from "../../lib/npn-vimeo-upload/util";
import VimeoUploadClient from "../../lib/npn-vimeo-upload/vimeo-client";

const STATUS_POLLING_INTERVAL_MILLIS = 10000;
const TITLE_MAX_LENGTH = 128;

function t(key, opts) {
  return i18n(`npn_vimeo_upload.${key}`, opts);
}

export function formatBytes(bytes) {
  if (bytes >= 1024 ** 3) {
    // "5 GB", "1.2 GB": one decimal, trailing ".0" dropped.
    return `${Number((bytes / 1024 ** 3).toFixed(1))} GB`;
  }
  if (bytes >= 1024 ** 2) {
    return `${Math.round(bytes / 1024 ** 2)} MB`;
  }
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function titleFromFileName(name) {
  return name
    .replace(/\.[^.]+$/, "")
    .replace(/[_-]+/g, " ")
    .trim()
    .slice(0, TITLE_MAX_LENGTH);
}

export default class NpnVimeoUpload extends Component {
  @service appEvents;
  @service dialog;
  @service siteSettings;

  @tracked file = null;
  @tracked title = "";
  @tracked fileError = null;
  @tracked isDragging = false;

  @tracked uploadProgress = 0;
  @tracked uploadedBytes = 0;
  @tracked isUploading = false;
  @tracked isProcessing = false;
  @tracked isPaused = false;
  @tracked isCancelling = false;
  @tracked uploadError = null;

  uploader = null;
  cancelRequested = false;
  dragDepth = 0;
  autoTitle = "";

  constructor() {
    super(...arguments);
    // Listen on the whole window while the modal is open: a file dropped
    // anywhere (header, footer, backdrop) is taken as the video instead of
    // the browser navigating away to play it, or the composer behind the
    // modal attaching it to the post.
    window.addEventListener("dragenter", this.onDragEnter, true);
    window.addEventListener("dragover", this.onDragOver, true);
    window.addEventListener("dragleave", this.onDragLeave, true);
    window.addEventListener("drop", this.onDrop, true);
  }

  willDestroy() {
    super.willDestroy(...arguments);
    window.removeEventListener("dragenter", this.onDragEnter, true);
    window.removeEventListener("dragover", this.onDragOver, true);
    window.removeEventListener("dragleave", this.onDragLeave, true);
    window.removeEventListener("drop", this.onDrop, true);
  }

  isFileDrag(event) {
    return [...(event.dataTransfer?.types ?? [])].includes("Files");
  }

  get maxSizeMb() {
    return this.siteSettings.npn_vimeo_upload_max_size_mb;
  }

  get maxSizeLabel() {
    return formatBytes(this.maxSizeMb * 1024 * 1024);
  }

  get isBusy() {
    return this.isUploading || this.isProcessing;
  }

  get canSubmit() {
    return this.file && this.title.trim() && !this.isBusy;
  }

  get fileSizeLabel() {
    return this.file ? formatBytes(this.file.size) : "";
  }

  get progressLabel() {
    return t("status.progress", {
      done: formatBytes(this.uploadedBytes),
      total: this.fileSizeLabel,
    });
  }

  get isModalDismissable() {
    return !this.isBusy || this.isPaused;
  }

  validateFile(file) {
    if (!file.type.startsWith("video/")) {
      return t("validation.video.invalid");
    }
    if (file.size > this.maxSizeMb * 1024 * 1024) {
      return t("validation.video.too_large", { max: this.maxSizeLabel });
    }
    return null;
  }

  selectFile(file) {
    if (!file || this.isBusy) {
      return;
    }

    this.uploadError = null;
    this.fileError = this.validateFile(file);

    if (this.fileError) {
      return;
    }

    // Keep a title the member already typed when they swap the file.
    if (!this.title.trim() || this.title === this.autoTitle) {
      this.title = titleFromFileName(file.name);
      this.autoTitle = this.title;
    }
    this.file = file;
  }

  @action
  onFileInput(event) {
    this.selectFile(event.target.files[0]);
    // Allow choosing the same file again after removing it.
    event.target.value = "";
  }

  @action
  removeFile() {
    this.file = null;
    this.fileError = null;
    this.uploadError = null;
    if (this.title === this.autoTitle) {
      this.title = "";
    }
  }

  @action
  onTitleInput(event) {
    this.title = event.target.value;
  }

  // dragenter/dragleave fire for every child element, so count depth to know
  // when the pointer has really left the zone.
  @action
  onDragEnter(event) {
    if (!this.isFileDrag(event)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    this.dragDepth++;
    this.isDragging = true;
  }

  @action
  onDragOver(event) {
    if (!this.isFileDrag(event)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    event.dataTransfer.dropEffect = this.isBusy ? "none" : "copy";
  }

  @action
  onDragLeave(event) {
    if (!this.isFileDrag(event)) {
      return;
    }
    this.dragDepth = Math.max(0, this.dragDepth - 1);
    if (this.dragDepth === 0) {
      this.isDragging = false;
    }
  }

  @action
  onDrop(event) {
    if (!this.isFileDrag(event)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    this.dragDepth = 0;
    this.isDragging = false;

    const files = [...(event.dataTransfer?.files ?? [])];
    if (files.length > 1) {
      this.fileError = t("validation.video.one_at_a_time");
      return;
    }
    this.selectFile(files[0]);
  }

  updateProgress({ loaded, total }) {
    this.uploadedBytes = Math.min(loaded, total);
    this.uploadProgress = Math.floor((loaded / total) * 100);
  }

  resetUpload() {
    this.uploadProgress = 0;
    this.uploadedBytes = 0;
    this.isUploading = false;
    this.isProcessing = false;
    this.isPaused = false;
    this.isCancelling = false;
    this.cancelRequested = false;
    this.uploader = null;
  }

  @action
  pauseUpload() {
    this.isPaused = true;
    this.uploader?.pause();
  }

  @action
  resumeUpload() {
    this.isPaused = false;
    this.uploader?.unpause();
  }

  @action
  async cancelUpload() {
    if (this.isCancelling) {
      return;
    }

    const confirmed = await this.dialog.yesNoConfirm({
      message: t("upload.cancel_confirm"),
    });
    if (!confirmed) {
      return;
    }

    this.isCancelling = true;
    this.cancelRequested = true;
    this.uploader?.cancel();
  }

  @action
  async submit(event) {
    event?.preventDefault();
    if (!this.canSubmit) {
      return;
    }

    this.resetUpload();
    this.uploadError = null;
    this.isUploading = true;

    const uploader = new VimeoUploadClient({
      file: this.file,
      metadata: { name: this.title.trim() },
      onProgress: (progress) => this.updateProgress(progress),
    });
    this.uploader = uploader;

    try {
      await uploader.upload();

      if (this.cancelRequested) {
        throw new CancelledError();
      }

      this.isUploading = false;
      this.isProcessing = true;

      await uploader.waitForTranscode({
        interval: STATUS_POLLING_INTERVAL_MILLIS,
        shouldCancel: () => this.cancelRequested,
      });

      const link =
        uploader.videoLink ?? `https://vimeo.com/${uploader.videoId}`;
      this.isProcessing = false;
      this.appEvents.trigger("composer:insert-block", `\n${link}\n`);
      this.args.closeModal();
    } catch (error) {
      if (error?.cancelled || this.cancelRequested) {
        try {
          await uploader.deleteVideo();
        } catch {
          // The video may not exist yet; nothing left to clean up.
        }
        this.resetUpload();
        return;
      }
      this.resetUpload();
      this.uploadError = uploadErrorMessage(error);
    }
  }

  <template>
    <DModal
      @title={{t "upload.video"}}
      @closeModal={{@closeModal}}
      @dismissable={{this.isModalDismissable}}
      class="npn-vimeo-upload-modal"
    >
      <:body>
        <form
          class="npn-vimeo-upload"
          {{on "submit" this.submit}}
        >
          {{#if this.file}}
            <div
              class={{concatClass
                "npn-vimeo-upload__file"
                (if this.isDragging "is-dragging")
              }}
            >
              <div class="npn-vimeo-upload__file-row">
                {{icon "file-video" class="npn-vimeo-upload__file-icon"}}
                <div class="npn-vimeo-upload__file-text">
                  <span class="npn-vimeo-upload__file-name">
                    {{this.file.name}}
                  </span>
                  <span class="npn-vimeo-upload__file-meta">
                    {{#if this.isUploading}}
                      {{#if this.isPaused}}
                        {{t "status.paused"}}
                        ·
                      {{/if}}
                      {{this.progressLabel}}
                    {{else if this.isProcessing}}
                      {{t "status.transcoding"}}
                    {{else}}
                      {{this.fileSizeLabel}}
                    {{/if}}
                  </span>
                </div>
                {{#unless this.isBusy}}
                  <DButton
                    @action={{this.removeFile}}
                    @icon="xmark"
                    @title="npn_vimeo_upload.upload.remove"
                    class="btn-flat btn-small npn-vimeo-upload__remove"
                  />
                {{/unless}}
              </div>

              {{#if this.isUploading}}
                <progress
                  class="npn-vimeo-upload__progress"
                  max="100"
                  value={{this.uploadProgress}}
                ></progress>
              {{else if this.isProcessing}}
                <progress
                  class="npn-vimeo-upload__progress is-indeterminate"
                ></progress>
              {{/if}}
            </div>
          {{else}}
            <label
              class={{concatClass
                "npn-vimeo-upload__dropzone"
                (if this.isDragging "is-dragging")
              }}
            >
              {{icon "npn-video-upload" class="npn-vimeo-upload__drop-icon"}}
              <span class="npn-vimeo-upload__drop-title">
                {{t "upload.drop_title"}}
              </span>
              <span class="npn-vimeo-upload__drop-browse">
                {{t "upload.drop_browse"}}
              </span>
              <span class="npn-vimeo-upload__drop-hint">
                {{t "upload.size_help" max=this.maxSizeLabel}}
              </span>
              <input
                type="file"
                accept="video/*"
                class="npn-vimeo-upload__input"
                {{on "change" this.onFileInput}}
              />
            </label>
          {{/if}}

          {{#if this.fileError}}
            <p class="npn-vimeo-upload__error" role="alert">
              {{icon "circle-exclamation"}}
              {{this.fileError}}
            </p>
          {{/if}}

          {{#if this.file}}
            <div class="npn-vimeo-upload__field">
              <label for="npn-vimeo-title">{{t "details.title"}}</label>
              <input
                id="npn-vimeo-title"
                type="text"
                maxlength={{TITLE_MAX_LENGTH}}
                value={{this.title}}
                disabled={{this.isBusy}}
                {{on "input" this.onTitleInput}}
              />
            </div>
          {{/if}}

          {{#if this.uploadError}}
            <p class="npn-vimeo-upload__error" role="alert">
              {{icon "circle-exclamation"}}
              {{t "status.error"}}:
              {{this.uploadError}}
            </p>
          {{/if}}
        </form>
      </:body>

      <:footer>
        {{#if this.isBusy}}
          {{#if this.isUploading}}
            {{#if this.isPaused}}
              <DButton
                @action={{this.resumeUpload}}
                @icon="play"
                @label="npn_vimeo_upload.upload.resume"
                class="btn-primary"
              />
            {{else}}
              <DButton
                @action={{this.pauseUpload}}
                @icon="pause"
                @label="npn_vimeo_upload.upload.pause"
              />
            {{/if}}
          {{/if}}
          <DButton
            @action={{this.cancelUpload}}
            @label={{if
              this.isCancelling
              "npn_vimeo_upload.status.cancelling"
              "npn_vimeo_upload.upload.cancel"
            }}
            @disabled={{this.isCancelling}}
            class="btn-flat npn-vimeo-upload__cancel"
          />
        {{else}}
          <DButton
            @action={{this.submit}}
            @icon="upload"
            @label="npn_vimeo_upload.upload.submit"
            @disabled={{if this.canSubmit false true}}
            class="btn-primary npn-vimeo-upload-submit"
          />
          <DButton
            @action={{@closeModal}}
            @label="npn_vimeo_upload.upload.close"
            class="btn-flat"
          />
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
