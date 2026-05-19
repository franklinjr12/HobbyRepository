class WakeAppJob < ApplicationJob
  queue_as :default

  def perform(app_id)
    app = App.find(app_id)

    app.with_lock do
      app.reload
      return unless app.status == "waking"

      RuntimeAgent.build.start_app(app)
    end
  end
end
