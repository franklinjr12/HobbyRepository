class RuntimeMetricSnapshot < ApplicationRecord
  belongs_to :app
  belongs_to :runtime_instance

  before_validation :assign_default_capture_time

  validates :captured_at, presence: true
  validates :memory_usage_bytes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :cpu_usage_percent, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :uptime_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  scope :recent, ->(limit = 20) { order(captured_at: :desc).limit(limit) }

  private

  def assign_default_capture_time
    self.captured_at ||= Time.current
  end
end
