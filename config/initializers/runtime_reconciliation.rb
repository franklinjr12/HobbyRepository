Rails.application.config.after_initialize do
  next if Rails.env.test?
  next if ENV["PLATFORM_SKIP_RUNTIME_RECONCILIATION"] == "1"

  RuntimeReconciler.new.reconcile!
rescue StandardError => error
  Rails.logger.warn("Runtime reconciliation skipped: #{error.class}: #{error.message}")
end
