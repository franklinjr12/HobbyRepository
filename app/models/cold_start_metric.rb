class ColdStartMetric < ApplicationRecord
  STATUSES = %w[succeeded failed].freeze

  belongs_to :app
  belongs_to :runtime_instance

  validates :started_at, :finished_at, :status, :total_wake_duration_ms, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :container_start_duration_ms,
            :health_check_duration_ms,
            :total_wake_duration_ms,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  scope :recent, ->(limit = 20) { order(started_at: :desc).limit(limit) }
  scope :succeeded, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
end
