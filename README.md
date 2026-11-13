# discourse-npn-vimeo-upload

Lets NPN members upload videos from the composer to NPN's Vimeo account without the
Vimeo token ever reaching a browser. It pairs with the `discourse-video-upload` theme
component, `npn-server-vimeo` branch.

## How it works

1. The member picks a video in the composer's upload modal (theme component).
2. The browser asks this plugin to start an upload (`POST /npn-vimeo/uploads`). The plugin
   checks that the member is in an allowed group, that the file is under the size limit, and
   that the member hasn't hit the daily limit. It then creates the video on Vimeo with NPN's
   token and returns only the per-video tus `upload_link`.
3. The browser sends the file straight to that link. The bytes never pass through the NPN
   server, and the link can't be used for anything except that one video.
4. The browser polls `GET /npn-vimeo/uploads/:id` for transcode status. A member can only
   see their own uploads.
5. On cancel, `DELETE /npn-vimeo/uploads/:id` removes the video. This only works for the
   member's own upload, and only within a day of creating it.

## Setup

1. Create a Vimeo app at https://developer.vimeo.com/apps and generate a personal access
   token for NPN's account with the scopes **public, upload, edit, delete**.
2. Add the plugin to `app.yml` and rebuild.
3. In Admin → Settings, search for `npn_vimeo_upload`:
   - `npn_vimeo_upload_access_token`: paste the token (stored as a secret setting)
   - `npn_vimeo_upload_allowed_groups`: who may upload (empty = no one)
   - `npn_vimeo_upload_max_size_mb`, `npn_vimeo_upload_daily_limit`
   - `npn_vimeo_upload_enabled`: on
4. In the theme component, enable `vimeo_upload_enabled`, leave `vimeo_oauth_client_id`
   empty, and set `allowed_groups` to match (that setting only hides the button).

If a token was ever pasted into the old theme component, regenerate it in Vimeo. Treat the
old one as public.
