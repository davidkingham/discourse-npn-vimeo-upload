import Component from "@glimmer/component";
import { cached, tracked } from "@glimmer/tracking";
import { action, getProperties } from "@ember/object";
import { service } from "@ember/service";
// Old import paths kept on purpose: newer core shims them, older core only
// has these, so the plugin works on either.
/* eslint-disable discourse/ui-kit-imports */
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
/* eslint-enable discourse/ui-kit-imports */
import Form from "discourse/components/form";
import { i18n } from "discourse-i18n";
import {
  CancelledError,
  uploadErrorMessage,
} from "../../lib/npn-vimeo-upload/util";
import VimeoUploadClient from "../../lib/npn-vimeo-upload/vimeo-client";

const STATUS_POLLING_INTERVAL_MILLIS = 10000;
const FORM_FIELDS = [
  "title",
  "description",
  "video",
  "viewPrivacy",
  "embedPrivacy",
];

function t(key, opts) {
  return i18n(`npn_vimeo_upload.${key}`, opts);
}

export default class NpnVimeoUpload extends Component {
  @service appEvents;
  @service dialog;
  @service siteSettings;

  @tracked uploadProgress = 0;
  @tracked isUploading = false;
  @tracked isProcessing = false;
  @tracked isPaused = false;
  @tracked uploadError = null;
  @tracked isCancelling = false;

  uploader = null;
  cancelRequested = false;

  viewPrivacy = this.siteSettings.npn_vimeo_upload_default_view_privacy;
  embedPrivacy = this.siteSettings.npn_vimeo_upload_default_embed_privacy;

  @cached
  get formData() {
    return getProperties(this, ...FORM_FIELDS);
  }

  get maxSizeMb() {
    return this.siteSettings.npn_vimeo_upload_max_size_mb;
  }

  get hasStatus() {
    return (
      this.isUploading ||
      this.isProcessing ||
      this.isPaused ||
      this.isCancelling ||
      this.uploadError
    );
  }

  get uploadDisabled() {
    return this.isUploading || this.isProcessing;
  }

  get isModalDismissable() {
    return !this.uploadDisabled || this.isPaused;
  }

  @action
  registerApi(api) {
    this.formApi = api;
  }

  fileError(file) {
    if (!file.type.startsWith("video/")) {
      return t("validation.video.invalid");
    }
    if (file.size > this.maxSizeMb * 1024 * 1024) {
      return t("validation.video.too_large", { max_mb: this.maxSizeMb });
    }
    return null;
  }

  @action
  validateVideoFile(event) {
    const input = event.target;
    const file = input.files[0];

    if (!file) {
      this.formApi.set("video", null);
      return;
    }

    const message = this.fileError(file);
    if (message) {
      this.formApi.set("video", null);
      input.value = "";
      this.formApi.addError("video", { title: t("upload.video"), message });
      return;
    }

    this.formApi.removeError("title");
    this.formApi.removeError("video");
    this.formApi.set("title", file.name);
    this.formApi.set("video", file);
  }

  @action
  validateUpload(data, { addError }) {
    if (!data.video) {
      addError("video", {
        title: t("upload.video"),
        message: t("validation.video.required"),
      });
    } else {
      const message = this.fileError(data.video);
      if (message) {
        addError("video", { title: t("upload.video"), message });
      }
    }

    if (!data.title) {
      addError("title", {
        title: t("details.title"),
        message: t("validation.title.required"),
      });
    }
  }

  updateProgress(data) {
    this.uploadProgress = Math.floor((data.loaded / data.total) * 100);
  }

  startUpload() {
    this.uploadProgress = 0;
    this.isUploading = true;
    this.isProcessing = false;
    this.isPaused = false;
    this.uploadError = null;
  }

  startProcessing() {
    this.uploadProgress = 0;
    this.isUploading = false;
    this.isProcessing = true;
  }

  failUpload(error) {
    this.uploadProgress = 0;
    this.isUploading = false;
    this.isProcessing = false;
    this.uploadError = uploadErrorMessage(error);
  }

  resetUpload() {
    this.uploadProgress = 0;
    this.isUploading = false;
    this.isProcessing = false;
    this.isPaused = false;
    this.isCancelling = false;
    this.uploadError = null;
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
  submitUpload() {
    this.formApi?.submit();
  }

  @action
  async handleSubmit(data) {
    this.startUpload();

    const uploader = new VimeoUploadClient({
      file: data.video,
      metadata: {
        name: data.title,
        description: data.description ?? "",
        viewPrivacy: data.viewPrivacy,
        embedPrivacy: data.embedPrivacy,
      },
      onProgress: (progress) => this.updateProgress(progress),
    });
    this.uploader = uploader;

    try {
      await uploader.upload();

      if (this.cancelRequested) {
        throw new CancelledError();
      }

      this.startProcessing();

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
      this.failUpload(error);
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
        <Form
          @data={{this.formData}}
          @onSubmit={{this.handleSubmit}}
          @validate={{this.validateUpload}}
          @onRegisterApi={{this.registerApi}}
          as |form|
        >
          <form.Field
            @name="video"
            @title={{t "upload.video"}}
            @type="custom"
            @format="full"
            @validation="required"
            @helpText={{t "upload.size_help" max_mb=this.maxSizeMb}}
            as |field|
          >
            <field.Control>
              <input
                type="file"
                id={{field.id}}
                accept="video/mp4,video/x-m4v,video/*"
                disabled={{this.uploadDisabled}}
                onchange={{this.validateVideoFile}}
              />
            </field.Control>
          </form.Field>

          <form.Field
            @name="title"
            @title={{t "details.title"}}
            @validation="required"
            @type="input"
            @format="full"
            as |field|
          >
            <field.Control
              id="npn-vimeo-title"
              disabled={{this.uploadDisabled}}
              placeholder={{t "details.title"}}
            />
          </form.Field>

          <form.Field
            @name="description"
            @title={{t "details.description"}}
            @type="input"
            @format="full"
            as |field|
          >
            <field.Control
              id="npn-vimeo-description"
              disabled={{this.uploadDisabled}}
              placeholder={{t "details.description"}}
            />
          </form.Field>

          <form.Field
            @name="viewPrivacy"
            @title={{t "details.view_privacy"}}
            @helpText={{t "details.view_privacy_help"}}
            @validation="required"
            @type="select"
            as |field|
          >
            <field.Control
              id="npn-vimeo-view-privacy"
              disabled={{this.uploadDisabled}}
              as |select|
            >
              <select.Option @value="anybody">
                {{t "details.view.anybody"}}
              </select.Option>
              <select.Option @value="unlisted">
                {{t "details.view.unlisted"}}
              </select.Option>
              <select.Option @value="disable">
                {{t "details.view.disable"}}
              </select.Option>
            </field.Control>
          </form.Field>

          <form.Field
            @name="embedPrivacy"
            @title={{t "details.embed_privacy"}}
            @validation="required"
            @type="select"
            as |field|
          >
            <field.Control
              id="npn-vimeo-embed-privacy"
              disabled={{this.uploadDisabled}}
              as |select|
            >
              <select.Option @value="public">
                {{t "details.embed.public"}}
              </select.Option>
              <select.Option @value="private">
                {{t "details.embed.private"}}
              </select.Option>
            </field.Control>
          </form.Field>
        </Form>
      </:body>

      <:footer>
        <DButton
          @action={{this.submitUpload}}
          @icon="fab-vimeo-v"
          @translatedLabel={{t "upload.vimeo"}}
          @disabled={{this.uploadDisabled}}
          class="btn-primary npn-vimeo-upload-submit"
        />

        {{#if this.hasStatus}}
          <div class="npn-vimeo-upload-status">
            {{#if this.isCancelling}}
              <div class="npn-vimeo-upload-status-line">
                <span>{{t "status.cancelling"}}</span>
                <div class="spinner"></div>
              </div>
            {{else}}
              {{#if this.isUploading}}
                <div class="npn-vimeo-upload-status-line">
                  <span>
                    {{#if this.isPaused}}
                      {{t "status.paused"}}
                    {{else}}
                      {{t "status.uploading"}}
                    {{/if}}
                    {{this.uploadProgress}}%
                  </span>
                  <div class="npn-vimeo-upload-controls">
                    {{#if this.isPaused}}
                      <DButton
                        @action={{this.resumeUpload}}
                        @icon="play"
                        @translatedLabel={{t "upload.resume"}}
                        class="btn-flat"
                      />
                    {{else}}
                      <DButton
                        @action={{this.pauseUpload}}
                        @icon="pause"
                        @translatedLabel={{t "upload.pause"}}
                        class="btn-flat"
                      />
                    {{/if}}
                    <DButton
                      @action={{this.cancelUpload}}
                      @icon="xmark"
                      @translatedLabel={{t "upload.cancel"}}
                      class="btn-flat"
                    />
                  </div>
                </div>
              {{/if}}

              {{#if this.isProcessing}}
                <div class="npn-vimeo-upload-status-line">
                  <span>{{t "status.transcoding"}}</span>
                  <div class="spinner"></div>
                  <div class="npn-vimeo-upload-controls">
                    <DButton
                      @action={{this.cancelUpload}}
                      @icon="xmark"
                      @translatedLabel={{t "upload.cancel"}}
                      class="btn-flat"
                    />
                  </div>
                </div>
              {{/if}}

              {{#if this.uploadError}}
                <div
                  class="npn-vimeo-upload-status-line npn-vimeo-upload-error"
                >
                  <span>{{t "status.error"}}: {{this.uploadError}}</span>
                </div>
              {{/if}}
            {{/if}}
          </div>
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
