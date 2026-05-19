# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

require "digest"

node = Node.ensure_local!

admin = User.find_or_initialize_by(email: ENV.fetch("SEED_USER_EMAIL", "admin@example.com"))
admin.assign_attributes(
  name: "Platform Admin",
  admin: true
)
admin.password = ENV.fetch("SEED_USER_PASSWORD", "password123") if admin.new_record? || ENV.key?("SEED_USER_PASSWORD")
admin.save!

def ensure_environment_variable!(app, key:, value:, secret: false)
  variable = app.environment_variables.find_or_initialize_by(key: key)
  variable.assign_attributes(value: value, secret: secret)
  variable.save!
end

def ensure_volume!(app, mount_path: Volume::DEFAULT_MOUNT_PATH)
  app.ensure_volume!(mount_path: mount_path)
  ensure_event!(
    app,
    event_type: "volume.created",
    message: "Persistent volume was configured for #{app.name}",
    metadata: app.volume.metadata
  )
end

def ensure_database_resource!(app, status: "available")
  database_resource = app.ensure_database_resource!
  database_resource.mark_provisioned! if status == "available" && !database_resource.available?
  database_resource.update!(status: status) unless database_resource.status == status
  ensure_event!(
    app,
    event_type: "database.created",
    message: "Shared database resource was configured for #{app.name}",
    metadata: database_resource.public_metadata
  )
  database_resource
end

def ensure_database_backup!(database_resource)
  backup = database_resource.database_backups.find_or_initialize_by(filename: "#{database_resource.database_name}-seed.sql")
  backup.status = "completed"
  backup.completed_at ||= Time.current
  backup.content = "-- Seed backup for #{database_resource.database_name}\n"
  backup.save!
end

def ensure_event!(app, event_type:, message:, metadata: {})
  app.app_events.find_or_create_by!(event_type: event_type, message: message) do |event|
    event.metadata = metadata
  end
end

def ensure_app_log!(app, runtime_instance:, stream:, logged_at:, message:)
  log = app.app_logs.find_or_initialize_by(
    runtime_instance: runtime_instance,
    deployment: runtime_instance.deployment,
    stream: stream,
    content_hash: Digest::SHA256.hexdigest(message)
  )
  log.logged_at ||= logged_at
  log.message = message
  log.save!
end

def ensure_current_deployment!(app, image_reference:, port:, health_check_path:, status: "deployed")
  deployment = app.deployments.find_or_initialize_by(image_reference: image_reference, port: port)
  deployment.assign_attributes(
    health_check_path: health_check_path,
    status: status,
    env_snapshot: app.runtime_environment,
    deployed_at: Time.current
  )
  deployment.save!
  deployment.mark_current!
  deployment
end

def ensure_runtime_instance!(app, status:, container_id: nil, deployment: app.current_deployment, **attributes)
  runtime_instance = if container_id.present?
    app.runtime_instances.find_or_initialize_by(container_id: container_id)
  else
    app.runtime_instances.find_or_initialize_by(status: status, deployment: deployment)
  end

  runtime_instance.assign_attributes(
    {
      status: status,
      deployment: deployment,
      node: app.node
    }.merge(attributes)
  )
  runtime_instance.save!
  runtime_instance
end

def ensure_demo_app!(owner:, node:, slug:, status:, **attributes)
  app = owner.apps.find_or_initialize_by(slug: slug)
  app.assign_attributes(
    {
      node: node,
      status: app.new_record? ? status : app.status
    }.merge(attributes)
  )
  app.save!

  app.manual_override_to!(status, reason: "seed demo lifecycle state") unless app.status == status
  app.routes.generated_subdomain.first_or_create!(
    hostname: Route.generated_hostname_for(app),
    active: true
  )

  app
end

sleepy_app = ensure_demo_app!(
  owner: admin,
  node: node,
  slug: "sleepy-landing-page",
  name: "Sleepy Landing Page",
  image_reference: "nginx:alpine",
  internal_port: 80,
  health_check_path: "/",
  idle_timeout_seconds: 300,
  startup_timeout_seconds: 45,
  memory_limit_bytes: 134_217_728,
  cpu_limit: 0.25,
  last_activity_at: 35.minutes.ago,
  last_request_at: 35.minutes.ago,
  status: "sleeping"
)
ensure_environment_variable!(sleepy_app, key: "APP_ENV", value: "demo")
ensure_environment_variable!(sleepy_app, key: "CACHE_MODE", value: "ephemeral")
ensure_volume!(sleepy_app, mount_path: "/usr/share/nginx/html/data")
ensure_current_deployment!(
  sleepy_app,
  image_reference: "nginx:alpine",
  port: 80,
  health_check_path: "/"
)
ensure_event!(
  sleepy_app,
  event_type: "runtime.idle_timeout_reached",
  message: "No inbound traffic for 5 minutes; app is ready to wake on demand.",
  metadata: { idle_timeout_seconds: sleepy_app.idle_timeout_seconds }
)

running_app = ensure_demo_app!(
  owner: admin,
  node: node,
  slug: "warm-whoami-api",
  name: "Warm Whoami API",
  image_reference: "traefik/whoami:v1.10",
  internal_port: 80,
  health_check_path: "/",
  idle_timeout_seconds: 900,
  startup_timeout_seconds: 30,
  memory_limit_bytes: 67_108_864,
  cpu_limit: 0.2,
  last_activity_at: 2.minutes.ago,
  last_request_at: 2.minutes.ago,
  status: "running"
)
ensure_environment_variable!(running_app, key: "REGION", value: "local")
ensure_environment_variable!(running_app, key: "REQUEST_LOG_LEVEL", value: "debug")
running_deployment = ensure_current_deployment!(
  running_app,
  image_reference: "traefik/whoami:v1.10",
  port: 80,
  health_check_path: "/"
)
running_runtime = ensure_runtime_instance!(
  running_app,
  status: "running",
  container_id: "seed-warm-whoami-api",
  deployment: running_deployment,
  internal_host: "172.18.0.20",
  internal_port: running_deployment.port,
  started_at: 12.minutes.ago,
  last_seen_at: 1.minute.ago
)
ensure_app_log!(
  running_app,
  runtime_instance: running_runtime,
  stream: "stdout",
  logged_at: 10.minutes.ago,
  message: "Server started on port #{running_deployment.port}"
)
ensure_app_log!(
  running_app,
  runtime_instance: running_runtime,
  stream: "stdout",
  logged_at: 2.minutes.ago,
  message: "GET / 200 3ms"
)
ensure_event!(
  running_app,
  event_type: "runtime.start_succeeded",
  message: "Container start requested for Warm Whoami API",
  metadata: {
    deployment_id: running_deployment.id,
    image_reference: running_deployment.image_reference,
    port: running_deployment.port
  }
)

failed_app = ensure_demo_app!(
  owner: admin,
  node: node,
  slug: "broken-health-check",
  name: "Broken Health Check",
  image_reference: "nginx:alpine",
  internal_port: 80,
  health_check_path: "/ready",
  idle_timeout_seconds: 600,
  startup_timeout_seconds: 10,
  memory_limit_bytes: 134_217_728,
  cpu_limit: 0.25,
  last_activity_at: 1.hour.ago,
  last_request_at: 1.hour.ago,
  status: "wake_failed"
)
ensure_environment_variable!(failed_app, key: "EXPECTED_HEALTH_PATH", value: "/ready")
failed_deployment = ensure_current_deployment!(
  failed_app,
  image_reference: "nginx:alpine",
  port: 80,
  health_check_path: "/ready",
  status: "failed"
)
failed_runtime = ensure_runtime_instance!(
  failed_app,
  status: "crashed",
  container_id: "seed-broken-health-check",
  deployment: failed_deployment,
  started_at: 1.hour.ago,
  stopped_at: 59.minutes.ago,
  last_seen_at: 59.minutes.ago,
  exit_code: 1,
  failure_message: "Health check GET /ready did not return success before the 10 second startup timeout."
)
ensure_app_log!(
  failed_app,
  runtime_instance: failed_runtime,
  stream: "stderr",
  logged_at: 58.minutes.ago,
  message: "Readiness endpoint /ready returned 404"
)
ensure_event!(
  failed_app,
  event_type: "health_check.failed",
  message: "Health check failed before the app became ready.",
  metadata: {
    health_check_path: failed_app.health_check_path,
    startup_timeout_seconds: failed_app.startup_timeout_seconds
  }
)

draft_app = ensure_demo_app!(
  owner: admin,
  node: node,
  slug: "draft-private-tool",
  name: "Draft Private Tool",
  image_reference: "ghcr.io/example/private-tool:latest",
  internal_port: 3000,
  health_check_path: "/up",
  idle_timeout_seconds: 1_800,
  startup_timeout_seconds: 60,
  memory_limit_bytes: 268_435_456,
  cpu_limit: 0.5,
  status: "created"
)
ensure_environment_variable!(draft_app, key: "RAILS_ENV", value: "production")
draft_database = ensure_database_resource!(draft_app, status: "available")
ensure_database_backup!(draft_database)
ensure_volume!(draft_app, mount_path: "/app/storage")
ensure_event!(
  draft_app,
  event_type: "app.review_needed",
  message: "Runtime settings are staged; create or replace the deployment when the image is ready.",
  metadata: { recommended_next_step: "verify image credentials" }
)

Rails.logger.info(
  "Seeded #{User.count} user, #{App.count} apps, #{Deployment.count} deployments, #{DatabaseResource.count} database resources, #{AppLog.count} app logs, and #{AppEvent.count} app events."
)
Rails.logger.info("Sign in with #{admin.email} / #{ENV.fetch('SEED_USER_PASSWORD', 'password123')}.")
