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

ActiveRecord::Schema[8.1].define(version: 2026_05_15_160200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "apps", force: :cascade do |t|
    t.decimal "cpu_limit", precision: 6, scale: 2
    t.datetime "created_at", null: false
    t.string "health_check_path", default: "/", null: false
    t.integer "idle_timeout_seconds", default: 900, null: false
    t.string "image_reference"
    t.integer "internal_port"
    t.datetime "last_activity_at"
    t.bigint "memory_limit_bytes"
    t.string "name", null: false
    t.bigint "node_id", null: false
    t.string "slug", null: false
    t.integer "startup_timeout_seconds", default: 60, null: false
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.index ["node_id"], name: "index_apps_on_node_id"
    t.index ["slug"], name: "index_apps_on_slug", unique: true
    t.index ["status"], name: "index_apps_on_status"
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

  create_table "runtime_instances", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "container_id"
    t.datetime "created_at", null: false
    t.integer "exit_code"
    t.string "failure_message"
    t.datetime "last_seen_at"
    t.bigint "node_id", null: false
    t.datetime "started_at"
    t.string "status", default: "starting", null: false
    t.datetime "stopped_at"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_runtime_instances_on_app_id"
    t.index ["container_id"], name: "index_runtime_instances_on_container_id", unique: true
    t.index ["node_id"], name: "index_runtime_instances_on_node_id"
    t.index ["status"], name: "index_runtime_instances_on_status"
  end

  add_foreign_key "apps", "nodes"
  add_foreign_key "runtime_instances", "apps"
  add_foreign_key "runtime_instances", "nodes"
end
