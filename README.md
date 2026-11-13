# discourse-npn-vimeo-upload

Adds a video upload button to the composer. NPN members in the allowed groups can upload a
video straight to NPN's Vimeo account, and the Vimeo link goes into their post. The Vimeo
token never reaches a browser.

The upload window and resumable uploader are adapted from Arkshine's modernized
[discourse-video-upload](https://github.com/Arkshine/discourse-video-upload/tree/modernize)
theme component, originally by ti0. YouTube and members' own Vimeo accounts were removed,
and the Vimeo calls that need the token moved to the server.

## How it works

1. A member clicks the video button in the composer, picks a file, and gives it a title.
   That's all they see: nothing about Vimeo or privacy.
2. The browser asks the plugin to start an upload (`POST /npn-vimeo/uploads`). The plugin
   checks that the member is in an allowed group, that the file is under the size limit, and
   that the member hasn't hit the daily limit. It then creates the video on Vimeo with NPN's
   token and returns only that video's tus `upload_link`.
3. The browser sends the file straight to that link, so it never passes through the NPN
   server. Uploads can be paused, resumed, and cancelled, and they retry if the connection
   drops.
4. The browser polls `GET /npn-vimeo/uploads/:id` until Vimeo finishes processing, then
   inserts the Vimeo link into the post. A member can only see their own uploads.
5. Cancelling calls `DELETE /npn-vimeo/uploads/:id`. This only works for the member's own
   upload, and only within a day of creating it.

## Setup

1. On NPN's Vimeo account, create an app at https://developer.vimeo.com/apps and generate a
   personal access token. Choose **Authenticated (you)** and the scopes **public, private, upload,
   edit, delete**. "Private" is needed to check processing on unlisted or hidden videos.
2. Add the plugin to `app.yml` and rebuild:
   `git clone https://github.com/davidkingham/discourse-npn-vimeo-upload.git`
3. In Admin → Settings, search for `npn_vimeo_upload`:
   - `npn_vimeo_upload_access_token`: paste the token (secret setting, server only)
   - `npn_vimeo_upload_allowed_groups`: who sees the button and may upload (empty = no one)
   - `npn_vimeo_upload_max_size_mb` (default 5120) and `npn_vimeo_upload_daily_limit`
     (default 10, admins exempt)
   - `npn_vimeo_upload_view_privacy` / `_embed_privacy`: privacy for every uploaded video.
     Members never see these. Unlisted and Hide from Vimeo need a paid Vimeo plan.
   - `npn_vimeo_upload_enabled`: on

If you installed the old Video Upload theme component, remove it so there aren't two video
buttons. If a Vimeo token was ever pasted into that component, regenerate it in Vimeo. Treat
the old one as public.
