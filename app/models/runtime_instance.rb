class RuntimeInstance < ApplicationRecord
  STATUSES = %w[starting running stopped crashed missing].freeze

  belongs_to :app
  belongs_to :node
  belongs_to :deployment, optional: true

  before_validation :assign_node_from_app
  before_validation :assign_deployment_from_app

  validates :status, inclusion: { in: STATUSES }
  validates :container_id, uniqueness: true, allow_blank: true
  validates :exit_code, numericality: { only_integer: true }, allow_nil: true

  private

  def assign_node_from_app
    self.node ||= app&.node
  end

  def assign_deployment_from_app
    self.deployment ||= app&.current_deployment
  end
end
