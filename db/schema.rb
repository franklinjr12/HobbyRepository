# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_19_170200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app_events", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "message", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_app_events_on_app_id"
    t.index ["created_at"], name: "index_app_events_on_created_at"
    t.index ["event_type"], name: "index_app_events_on_event_type"
  end

  create_table "app_logs", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "content_hash", null: false
    t.datetime "created_at", null: false
    t.bigint "deployment_id"
    t.datetime "logged_at", null: false
    t.text "message", null: false
    t.bigint "runtime_instance_id"
    t.string "stream", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "logged_at"], name: "index_app_logs_on_app_id_and_logged_at"
    t.index ["app_id"], name: "index_app_logs_on_app_id"
    t.index ["deployment_id"], name: "index_app_logs_on_deployment_id"
    t.index ["runtime_instance_id", "stream", "logged_at", "content_hash"], name: "index_app_logs_on_runtime_stream_time_hash", unique: true
    t.index ["runtime_instance_id"], name: "index_app_logs_on_runtime_instance_id"
    t.index ["stream"], name: "index_app_logs_on_stream"
  end

  create_table "app_request_metrics", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.boolean "cold_start", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "occurred_at", null: false
    t.string "path"
    t.string "request_method"
    t.integer "status_code"
    t.datetime "updated_at", null: false
    t.integer "wake_duration_ms"
    t.index ["app_id", "cold_start"], name: "index_app_request_metrics_on_app_id_and_cold_start"
    t.index ["app_id", "occurred_at"], name: "index_app_request_metrics_on_app_id_and_occurred_at"
    t.index ["app_id"], name: "index_app_request_metrics_on_app_id"
    t.index ["status_code"], name: "index_app_request_metrics_on_status_code"
  end

  create_table "apps", force: :cascade do |t|
    t.integer "active_connection_count", default: 0, null: false
    t.integer "active_request_count", default: 0, null: false
    t.decimal "cpu_limit", precision: 6, scale: 2
    t.datetime "created_at", null: false
    t.datetime "drain_started_at"
    t.string "health_check_kind", default: "http", null: false
    t.string "health_check_path", default: "/"
    t.integer "idle_timeout_seconds", default: 900, null: false
    t.string "image_reference"
    t.integer "internal_port"
    t.datetime "last_activity_at"
    t.datetime "last_request_at"
    t.bigint "memory_limit_bytes"
    t.string "name", null: false
    t.bigint "node_id", null: false
    t.bigint "owner_id"
    t.string "slug", null: false
    t.integer "startup_timeout_seconds", default: 60, null: false
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.index ["drain_started_at"], name: "index_apps_on_drain_started_at"
    t.index ["last_request_at"], name: "index_apps_on_last_request_at"
    t.index ["node_id"], name: "index_apps_on_node_id"
    t.index ["owner_id"], name: "index_apps_on_owner_id"
    t.index ["slug"], name: "index_apps_on_slug", unique: true
    t.index ["status"], name: "index_apps_on_status"
  end

  create_table "cold_start_metrics", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.integer "container_start_duration_ms"
    t.datetime "created_at", null: false
    t.text "failure_message"
    t.datetime "finished_at", null: false
    t.integer "health_check_duration_ms"
    t.bigint "runtime_instance_id", null: false
    t.datetime "started_at", null: false
    t.string "status", null: false
    t.integer "total_wake_duration_ms", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "started_at"], name: "index_cold_start_metrics_on_app_id_and_started_at"
    t.index ["app_id", "status"], name: "index_cold_start_metrics_on_app_id_and_status"
    t.index ["app_id"], name: "index_cold_start_metrics_on_app_id"
    t.index ["runtime_instance_id"], name: "index_cold_start_metrics_on_runtime_instance_id"
    t.index ["status"], name: "index_cold_start_metrics_on_status"
  end

  create_table "database_backups", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "database_resource_id", null: false
    t.text "encrypted_content"
    t.text "failure_message"
    t.string "filename", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["database_resource_id"], name: "index_database_backups_on_database_resource_id"
    t.index ["status"], name: "index_database_backups_on_status"
  end

  create_table "database_resources", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.datetime "credentials_rotated_at"
    t.string "database_name", null: false
    t.string "database_name_env_var", default: "DATABASE_NAME", null: false
    t.string "database_type", default: "postgres", null: false
    t.string "database_url_env_var", default: "DATABASE_URL", null: false
    t.text "encrypted_password", null: false
    t.text "failure_message"
    t.string "host", default: "localhost", null: false
    t.string "host_env_var", default: "DATABASE_HOST", null: false
    t.string "password_env_var", default: "DATABASE_PASSWORD", null: false
    t.integer "port", default: 5432, null: false
    t.string "port_env_var", default: "DATABASE_PORT", null: false
    t.datetime "provisioned_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.string "username_env_var", default: "DATABASE_USERNAME", null: false
    t.index ["app_id"], name: "index_database_resources_on_app_id", unique: true
    t.index ["database_name"], name: "index_database_resources_on_database_name", unique: true
    t.index ["status"], name: "index_database_resources_on_status"
    t.index ["username"], name: "index_database_resources_on_username", unique: true
  end

  create_table "deployments", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.boolean "current", default: false, null: false
    t.datetime "deployed_at"
    t.jsonb "env_snapshot", default: {}, null: false
    t.string "health_check_kind", default: "http", null: false
    t.string "health_check_path", default: "/"
    t.string "image_reference", null: false
    t.integer "port", null: false
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "current"], name: "index_deployments_on_current_app", unique: true, where: "current"
    t.index ["app_id"], name: "index_deployments_on_app_id"
    t.index ["status"], name: "index_deployments_on_status"
  end

  create_table "environment_variables", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.boolean "secret", default: false, null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["app_id", "key"], name: "index_environment_variables_on_app_id_and_key", unique: true
    t.index ["app_id"], name: "index_environment_variables_on_app_id"
  end

  create_table "nodes", force: :cascade do |t|
    t.decimal "capacity_cpu", precision: 8, scale: 2
    t.bigint "capacity_memory_bytes"
    t.datetime "created_at", null: false
    t.string "hostname", null: false
    t.datetime "last_heartbeat_at"
    t.boolean "local", default: false, null: false
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["hostname"], name: "index_nodes_on_hostname", unique: true
    t.index ["local"], name: "index_nodes_on_local", unique: true, where: "local"
    t.index ["status"], name: "index_nodes_on_status"
  end

  create_table "routes", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "hostname", null: false
    t.string "route_type", default: "generated_subdomain", null: false
    t.string "tls_status", default: "not_configured", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_routes_on_active"
    t.index ["app_id"], name: "index_routes_on_app_id"
    t.index ["hostname"], name: "index_routes_on_hostname", unique: true
    t.index ["route_type"], name: "index_routes_on_route_type"
  end

  create_table "runtime_instances", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "container_id"
    t.datetime "created_at", null: false
    t.bigint "deployment_id"
    t.integer "exit_code"
    t.string "failure_message"
    t.datetime "health_check_checked_at"
    t.string "health_check_result"
    t.integer "health_check_status_code"
    t.string "internal_host"
    t.integer "internal_port"
    t.datetime "last_seen_at"
    t.bigint "node_id", null: false
    t.datetime "started_at"
    t.string "status", default: "starting", null: false
    t.datetime "stopped_at"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_runtime_instances_on_app_id"
    t.index ["container_id"], name: "index_runtime_instances_on_container_id", unique: true
    t.index ["deployment_id"], name: "index_runtime_instances_on_deployment_id"
    t.index ["node_id"], name: "index_runtime_instances_on_node_id"
    t.index ["status"], name: "index_runtime_instances_on_status"
  end

  create_table "runtime_metric_snapshots", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "captured_at", null: false
    t.decimal "cpu_usage_percent", precision: 8, scale: 3
    t.datetime "created_at", null: false
    t.bigint "memory_usage_bytes"
    t.bigint "runtime_instance_id", null: false
    t.datetime "updated_at", null: false
    t.integer "uptime_seconds"
    t.index ["app_id", "captured_at"], name: "index_runtime_metric_snapshots_on_app_id_and_captured_at"
    t.index ["app_id"], name: "index_runtime_metric_snapshots_on_app_id"
    t.index ["runtime_instance_id", "captured_at"], name: "index_runtime_metrics_on_runtime_and_captured_at"
    t.index ["runtime_instance_id"], name: "index_runtime_metric_snapshots_on_runtime_instance_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "volumes", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "host_path", null: false
    t.string "mount_path", null: false
    t.bigint "size_limit_bytes"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_volumes_on_app_id", unique: true
    t.index ["host_path"], name: "index_volumes_on_host_path", unique: true
    t.index ["status"], name: "index_volumes_on_status"
  end

  add_foreign_key "app_events", "apps"
  add_foreign_key "app_logs", "apps"
  add_foreign_key "app_logs", "deployments"
  add_foreign_key "app_logs", "runtime_instances"
  add_foreign_key "app_request_metrics", "apps"
  add_foreign_key "apps", "nodes"
  add_foreign_key "apps", "users", column: "owner_id"
  add_foreign_key "cold_start_metrics", "apps"
  add_foreign_key "cold_start_metrics", "runtime_instances"
  add_foreign_key "database_backups", "database_resources"
  add_foreign_key "database_resources", "apps"
  add_foreign_key "deployments", "apps"
  add_foreign_key "environment_variables", "apps"
  add_foreign_key "routes", "apps"
  add_foreign_key "runtime_instances", "apps"
  add_foreign_key "runtime_instances", "deployments"
  add_foreign_key "runtime_instances", "nodes"
  add_foreign_key "runtime_metric_snapshots", "apps"
  add_foreign_key "runtime_metric_snapshots", "runtime_instances"
  add_foreign_key "volumes", "apps"
end
