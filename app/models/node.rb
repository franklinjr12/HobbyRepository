require "socket"

class Node < ApplicationRecord
  STATUSES = %w[active degraded offline retired].freeze

  has_many :apps, dependent: :restrict_with_error
  has_many :runtime_instances, dependent: :restrict_with_error

  validates :name, :hostname, presence: true
  validates :hostname, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :local, uniqueness: true, if: :local?
  validates :capacity_cpu, numericality: { greater_than: 0 }, allow_nil: true
  validates :capacity_memory_bytes, numericality: { only_integer: true, greater_than: 0 },
                                    allow_nil: true

  scope :local, -> { where(local: true) }
  scope :active, -> { where(status: "active") }

  def self.ensure_local!
    local.first_or_create!(
      name: ENV.fetch("PLATFORM_NODE_NAME", "local"),
      hostname: ENV.fetch("PLATFORM_NODE_HOSTNAME", Socket.gethostname),
      status: "active",
      last_heartbeat_at: Time.current
    )
  end
end
