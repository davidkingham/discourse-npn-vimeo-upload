# frozen_string_literal: true

module ::NpnVimeoUpload
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace NpnVimeoUpload
  end
end
