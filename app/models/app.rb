class App < ApplicationRecord
  DEFAULT_IDLE_TIMEOUT_SECONDS = 900
  DEFAULT_STARTUP_TIMEOUT_SECONDS = 60
  DEFAULT_HEALTH_CHECK_PATH = "/".freeze

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

  belongs_to :node
  has_many :runtime_instances, dependent: :restrict_with_error

  before_validation :assign_local_node, on: :create
  before_validation :normalize_slug
  before_validation :assign_defaults

  validates :name, :slug, :status, presence: true
  validates :slug, uniqueness: true,
                   format: {
                     with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                     message: "must use lowercase letters, numbers, and hyphens"
                   }
  validates :status, inclusion: { in: STATUSES }
  validates :internal_port,
            numericality: { only_integer: true, greater_than: 0, less_than: 65_536 },
            allow_nil: true
  validates :idle_timeout_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 60 }
  validates :startup_timeout_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :memory_limit_bytes, numericality: { only_integer: true, greater_than: 0 },
                                 allow_nil: true
  validates :cpu_limit, numericality: { greater_than: 0 }, allow_nil: true
  validate :status_transition_must_be_valid, if: :will_save_change_to_status?

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

  private

  def assign_defaults
    self.health_check_path = DEFAULT_HEALTH_CHECK_PATH if health_check_path.blank?
    self.idle_timeout_seconds ||= DEFAULT_IDLE_TIMEOUT_SECONDS
    self.startup_timeout_seconds ||= DEFAULT_STARTUP_TIMEOUT_SECONDS
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
end
