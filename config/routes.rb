# frozen_string_literal: true

NpnVimeoUpload::Engine.routes.draw do
  post "uploads" => "uploads#create"
  get "uploads/:video_id" => "uploads#show", :constraints => { video_id: /\d+/ }
  delete "uploads/:video_id" => "uploads#destroy", :constraints => { video_id: /\d+/ }
end

Discourse::Application.routes.draw { mount ::NpnVimeoUpload::Engine, at: "npn-vimeo" }
