class App < ApplicationRecord
  DEFAULT_IDLE_TIMEOUT_SECONDS = 900
  DEFAULT_STARTUP_TIMEOUT_SECONDS = 60
  DEFAULT_HEALTH_CHECK_PATH = "/".freeze
  DEFAULT_HEALTH_CHECK_KIND = "http".freeze
  DEFAULT_DRAIN_TIMEOUT_SECONDS = 30
  DEFAULT_MEMORY_LIMIT_BYTES = ENV.fetch("PLATFORM_DEFAULT_MEMORY_LIMIT_BYTES", 256.megabytes).to_i

  HEALTH_CHECK_KINDS = %w[http port].freeze

  STATUSES = %w[
    created
    deploying
    sleeping
    waking
    running
    draining
    stopping
    stopped
    crashed
    unhealthy
    wake_failed
  ].freeze

  VALID_TRANSITIONS = {
    "created" => %w[deploying sleeping stopped],
    "deploying" => %w[sleeping running wake_failed],
    "sleeping" => %w[waking stopped],
    "waking" => %w[running wake_failed crashed sleeping],
    "running" => %w[draining stopping crashed unhealthy],
    "draining" => %w[sleeping running stopping],
    "stopping" => %w[sleeping stopped crashed],
    "stopped" => %w[waking sleeping],
    "crashed" => %w[waking stopped sleeping],
    "unhealthy" => %w[waking stopping sleeping],
    "wake_failed" => %w[waking stopped sleeping]
  }.freeze

  RESTART_RESTORE_STATUSES = {
    "deploying" => "created",
    "waking" => "sleeping",
    "running" => "sleeping",
    "draining" => "sleeping",
    "stopping" => "sleeping"
  }.freeze

  attr_accessor :manual_status_override_reason, :restoring_after_platform_restart
  attr_accessor :volume_enabled, :volume_mount_path
  attr_accessor :database_enabled, :database_type

  belongs_to :owner, class_name: "User", inverse_of: :apps
  belongs_to :node
  has_many :runtime_instances, dependent: :restrict_with_error
  has_many :deployments, dependent: :restrict_with_error
  has_many :routes, dependent: :restrict_with_error
  has_many :app_events, dependent: :destroy
  has_many :app_logs, dependent: :destroy
  has_many :app_request_metrics, dependent: :destroy
  has_many :runtime_metric_snapshots, dependent: :destroy
  has_many :cold_start_metrics, dependent: :destroy
  has_many :environment_variables, dependent: :destroy
  has_one :volume, dependent: :restrict_with_error
  has_one :database_resource, dependent: :restrict_with_error

  before_validation :assign_local_node, on: :create
  before_validation :normalize_slug
  before_validation :assign_defaults
  after_create :create_default_route
  after_create :create_requested_volume
  after_create :create_requested_database_resource
  after_create :record_creation_event

  validates :name, :slug, :status, presence: true
  validates :image_reference, format: {
    with: Deployment::IMAGE_REFERENCE_FORMAT,
    message: "must be a valid container image reference"
  }, allow_blank: true
  validates :slug, uniqueness: true,
                   format: {
                     with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                     message: "must use lowercase letters, numbers, and hyphens"
                   }
  validates :status, inclusion: { in: STATUSES }
  validates :health_check_kind, inclusion: { in: HEALTH_CHECK_KINDS }
  validates :health_check_path, presence: true, if: :http_health_check?
  validates :health_check_path, format: { with: %r{\A/[^\r\n]*\z}, message: "must start with /" },
                                allow_blank: true
  validates :internal_port,
            numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
            allow_nil: true
  validates :idle_timeout_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 60 }
  validates :startup_timeout_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :memory_limit_bytes, numericality: { only_integer: true, greater_than: 0 }
  validates :cpu_limit, numericality: { greater_than: 0 }, allow_nil: true
  validate :status_transition_must_be_valid, if: :will_save_change_to_status?
  validate :requested_volume_mount_path_must_be_valid, if: :volume_requested?

  scope :running, -> { where(status: "running") }
  scope :draining, -> { where(status: "draining") }

  def may_transition_to?(next_status)
    self.class.valid_transition?(status, next_status)
  end

  def transition_to!(next_status)
    raise ArgumentError, "unknown app status: #{next_status}" unless STATUSES.include?(next_status)

    update!(status: next_status)
  end

  def manual_override_to!(next_status, reason:)
    raise ArgumentError, "manual override reason is required" if reason.blank?
    raise ArgumentError, "unknown app status: #{next_status}" unless STATUSES.include?(next_status)

    self.manual_status_override_reason = reason
    update!(status: next_status)
  ensure
    self.manual_status_override_reason = nil
  end

  def restore_status_after_platform_restart!
    restored_status = RESTART_RESTORE_STATUSES.fetch(status, status)
    self.restoring_after_platform_restart = true
    update!(status: restored_status)
  ensure
    self.restoring_after_platform_restart = false
  end

  def self.valid_transition?(from_status, to_status)
    return true if from_status == to_status

    VALID_TRANSITIONS.fetch(from_status, []).include?(to_status)
  end

  def current_deployment
    deployments.find_by(current: true)
  end

  def default_route
    routes.generated_subdomain.first || routes.first
  end

  def record_event!(event_type, message, metadata: {})
    app_events.create!(event_type: event_type, message: message, metadata: metadata)
  end

  def runtime_environment
    environment_variables.to_h(&:runtime_pair).merge(database_resource&.runtime_environment || {})
  end

  def runtime_environment_metadata
    variables = environment_variables.ordered
    database_env_keys = database_resource&.available? ? database_resource.env_var_names : []

    {
      variable_count: variables.size + database_env_keys.size,
      secret_count: variables.count(&:secret?) + database_env_keys.size,
      keys: variables.map(&:key) + database_env_keys
    }
  end

  def storage_volume_enabled?
    volume_requested? || volume&.active?
  end

  def shared_database_enabled?
    database_requested? || (database_resource.present? && database_resource.status != "disabled")
  end

  def active_volume
    volume if volume&.active?
  end

  def volume_requested?
    ActiveModel::Type::Boolean.new.cast(volume_enabled)
  end

  def database_requested?
    ActiveModel::Type::Boolean.new.cast(database_enabled)
  end

  def ensure_volume!(mount_path: nil)
    selected_mount_path = mount_path.presence || volume_mount_path.presence || Volume::DEFAULT_MOUNT_PATH

    transaction do
      if volume
        volume.update!(mount_path: selected_mount_path, status: "active")
        volume.ensure_host_directory!
      else
        create_volume!(mount_path: selected_mount_path)
      end
    end
  end

  def record_runtime_environment_prepared!
    record_event!(
      "runtime.environment_prepared",
      "Runtime environment prepared for #{name}",
      metadata: runtime_environment_metadata
    )
  end

  def ensure_database_resource!(database_type: nil)
    if database_resource
      database_resource.update!(
        database_type: database_type.presence || database_resource.database_type,
        status: database_resource.status == "disabled" ? "pending" : database_resource.status
      )
      database_resource
    else
      create_database_resource!(database_type: database_type.presence || DatabaseResource::DEFAULT_DATABASE_TYPE)
    end
  end

  def record_request_started!(connection: false, at: Time.current)
    with_lock do
      next_active_connection_count = active_connection_count + (connection ? 1 : 0)
      update!(
        active_request_count: active_request_count + 1,
        active_connection_count: next_active_connection_count,
        last_request_at: at,
        last_activity_at: at
      )

      if status == "draining"
        manual_override_to!("running", reason: "new traffic cancelled sleep drain")
        record_event!(
          "sleep.cancelled",
          "Sleep was cancelled for #{name} because new traffic arrived",
          metadata: active_activity_metadata
        )
      end
    end
  end

  def record_request_finished!(connection: false, at: Time.current)
    with_lock do
      decrement_counter_safely!(:active_request_count)
      decrement_counter_safely!(:active_connection_count) if connection
      update!(last_activity_at: at)
    end
  end

  def record_request_activity!(at: Time.current)
    update!(last_request_at: at, last_activity_at: at)
  end

  def record_request_metric!(status_code: nil, cold_start: false, wake_duration_ms: nil,
                             request_method: nil, path: nil, at: Time.current)
    app_request_metrics.create!(
      occurred_at: at,
      status_code: status_code,
      cold_start: cold_start,
      wake_duration_ms: wake_duration_ms,
      request_method: request_method,
      path: path
    )
  end

  def request_count
    app_request_metrics.count
  end

  def cold_start_count
    app_request_metrics.cold_starts.count
  end

  def average_wake_duration_ms
    cold_start_metrics.succeeded.average(:total_wake_duration_ms)&.round
  end

  def active_runtime_activity?
    active_request_count.positive? || active_connection_count.positive?
  end

  def idle_sleep_due?(now: Time.current)
    return false unless idle_timeout_reached?(now: now)
    return false if active_runtime_activity?

    true
  end

  def idle_timeout_reached?(now: Time.current)
    return false unless status == "running"

    last_activity = last_request_at || last_activity_at || updated_at
    last_activity <= idle_timeout_seconds.seconds.ago(now)
  end

  def begin_sleep_drain!(requested_by:, trigger:, at: Time.current, force: false, wait_for_activity: false)
    return false if !force && !wait_for_activity && active_runtime_activity?

    manual_override_to!("draining", reason: "#{trigger} sleep requested")
    update!(drain_started_at: at)
    record_event!(
      "sleep.started",
      "Sleep started for #{name}",
      metadata: active_activity_metadata.merge(
        requested_by: requested_by,
        trigger: trigger,
        forced: force,
        waiting_for_activity: wait_for_activity
      )
    )
    true
  end

  def mark_sleep_succeeded!(requested_by:, trigger:)
    manual_override_to!("sleeping", reason: "#{trigger} sleep completed")
    update!(drain_started_at: nil, active_request_count: 0, active_connection_count: 0)
    record_event!(
      "sleep.succeeded",
      "#{name} is sleeping",
      metadata: { requested_by: requested_by, trigger: trigger }
    )
  end

  def drain_timeout_expired?(now: Time.current)
    drain_started_at.present? && drain_started_at <= DEFAULT_DRAIN_TIMEOUT_SECONDS.seconds.ago(now)
  end

  def http_health_check?
    health_check_kind == "http"
  end

  def port_health_check?
    health_check_kind == "port"
  end

  private

  def assign_defaults
    self.health_check_kind = DEFAULT_HEALTH_CHECK_KIND if health_check_kind.blank?
    self.health_check_path = DEFAULT_HEALTH_CHECK_PATH if http_health_check? && health_check_path.blank?
    self.health_check_path = nil if port_health_check?
    self.idle_timeout_seconds ||= DEFAULT_IDLE_TIMEOUT_SECONDS
    self.startup_timeout_seconds ||= DEFAULT_STARTUP_TIMEOUT_SECONDS
    self.memory_limit_bytes ||= DEFAULT_MEMORY_LIMIT_BYTES
    self.active_request_count ||= 0
    self.active_connection_count ||= 0
  end

  def assign_local_node
    self.node ||= Node.ensure_local!
  end

  def normalize_slug
    self.slug = slug.to_s.parameterize if slug.present?
    self.slug = name.to_s.parameterize if slug.blank? && name.present?
  end

  def status_transition_must_be_valid
    return if new_record? || manual_status_override_reason.present? || restoring_after_platform_restart

    previous_status, next_status = status_change_to_be_saved
    return if self.class.valid_transition?(previous_status, next_status)

    errors.add(:status, "cannot transition from #{previous_status} to #{next_status}")
  end

  def create_default_route
    routes.create!(
      hostname: Route.generated_hostname_for(self),
      route_type: "generated_subdomain",
      active: true
    )
  end

  def record_creation_event
    record_event!(
      "app.created",
      "#{name} was created",
      metadata: {
        slug: slug,
        status: status,
        node_id: node_id
      }
    )
  end

  def create_requested_volume
    return unless volume_requested?

    ensure_volume!(mount_path: volume_mount_path)
    record_event!(
      "volume.created",
      "Persistent volume was created for #{name}",
      metadata: volume.metadata
    )
  end

  def create_requested_database_resource
    return unless database_requested?

    ensure_database_resource!(database_type: database_type)
    record_event!(
      "database.created",
      "Shared database resource was configured for #{name}",
      metadata: database_resource.public_metadata
    )
  end

  def decrement_counter_safely!(attribute)
    current_value = public_send(attribute).to_i
    update!(attribute => [ current_value - 1, 0 ].max)
  end

  def active_activity_metadata
    {
      active_request_count: active_request_count,
      active_connection_count: active_connection_count,
      last_request_at: last_request_at&.iso8601,
      idle_timeout_seconds: idle_timeout_seconds
    }.compact
  end

  def requested_volume_mount_path_must_be_valid
    candidate = Volume.new(mount_path: volume_mount_path.presence || Volume::DEFAULT_MOUNT_PATH, host_path: "placeholder")
    return if candidate.valid?

    candidate.errors[:mount_path].each { |message| errors.add(:volume_mount_path, message) }
  end
end
