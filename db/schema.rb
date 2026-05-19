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

ActiveRecord::Schema[8.1].define(version: 2026_05_19_120000) do
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

  create_table "apps", force: :cascade do |t|
    t.decimal "cpu_limit", precision: 6, scale: 2
    t.datetime "created_at", null: false
    t.string "health_check_kind", default: "http", null: false
    t.string "health_check_path", default: "/"
    t.integer "idle_timeout_seconds", default: 900, null: false
    t.string "image_reference"
    t.integer "internal_port"
    t.datetime "last_activity_at"
    t.bigint "memory_limit_bytes"
    t.string "name", null: false
    t.bigint "node_id", null: false
    t.bigint "owner_id"
    t.string "slug", null: false
    t.integer "startup_timeout_seconds", default: 60, null: false
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.index ["node_id"], name: "index_apps_on_node_id"
    t.index ["owner_id"], name: "index_apps_on_owner_id"
    t.index ["slug"], name: "index_apps_on_slug", unique: true
    t.index ["status"], name: "index_apps_on_status"
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

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "app_events", "apps"
  add_foreign_key "apps", "nodes"
  add_foreign_key "apps", "users", column: "owner_id"
  add_foreign_key "deployments", "apps"
  add_foreign_key "environment_variables", "apps"
  add_foreign_key "routes", "apps"
  add_foreign_key "runtime_instances", "apps"
  add_foreign_key "runtime_instances", "deployments"
  add_foreign_key "runtime_instances", "nodes"
end
