class RuntimeReconciler
  ACTIVE_RUNTIME_STATUSES = %w[starting running].freeze
  ACTIVE_CONTAINER_STATES = %w[created restarting running paused].freeze

  Result = Data.define(:checked_containers, :missing_runtime_ids, :orphaned_container_ids)

  def initialize(runtime_agent: RuntimeAgent.build)
    @runtime_agent = runtime_agent
  end

  def reconcile!
    result = runtime_agent.list_platform_containers
    return Result.new(0, [], []) unless result.success?

    containers = result.payload.fetch(:containers)
    seen_container_ids = containers.filter_map { |container| container[:container_id] }
    sync_known_containers!(containers)
    missing_runtime_ids = mark_missing_runtimes!(seen_container_ids)
    orphaned_container_ids = mark_orphaned_containers!(containers)

    Result.new(containers.size, missing_runtime_ids, orphaned_container_ids)
  end

  private

  attr_reader :runtime_agent

  def sync_known_containers!(containers)
    containers.each do |container|
      runtime_instance = RuntimeInstance.find_by(container_id: container[:container_id])
      next unless runtime_instance

      next_status = active_container?(container) ? "running" : "stopped"
      status_changed = runtime_instance.status != next_status
      runtime_instance.update!(
        status: next_status,
        last_seen_at: Time.current,
        stopped_at: active_container?(container) ? nil : Time.current
      )
      runtime_instance.app.manual_override_to!(next_status, reason: "startup reconciliation container sync")

      next unless status_changed

      runtime_instance.app.record_event!(
        "runtime.recovery_synced",
        "Runtime container state was synced during startup reconciliation.",
        metadata: {
          runtime_instance_id: runtime_instance.id,
          container_id: runtime_instance.container_id,
          runtime_status: next_status
        }
      )
    end
  end

  def mark_missing_runtimes!(seen_container_ids)
    RuntimeInstance.where(status: ACTIVE_RUNTIME_STATUSES).where.not(container_id: nil).filter_map do |runtime_instance|
      next if seen_container_ids.include?(runtime_instance.container_id)

      runtime_instance.update!(
        status: "missing",
        stopped_at: Time.current,
        last_seen_at: Time.current,
        failure_message: "Container was not found during startup reconciliation."
      )
      runtime_instance.app.manual_override_to!("crashed", reason: "startup reconciliation missing container")
      runtime_instance.app.record_event!(
        "runtime.recovery_missing",
        "Runtime container was missing during startup reconciliation.",
        metadata: {
          runtime_instance_id: runtime_instance.id,
          container_id: runtime_instance.container_id
        }
      )
      runtime_instance.id
    end
  end

  def mark_orphaned_containers!(containers)
    containers.filter_map do |container|
      container_id = container[:container_id]
      next if container_id.blank? || RuntimeInstance.exists?(container_id: container_id)
      next unless active_container?(container)

      app = app_for(container)
      next unless app

      runtime_instance = app.runtime_instances.create!(
        container_id: container_id,
        status: "orphaned",
        last_seen_at: Time.current,
        failure_message: "Container was found without a matching runtime instance during startup reconciliation."
      )
      app.record_event!(
        "runtime.recovery_orphaned",
        "Orphaned runtime container was found during startup reconciliation.",
        metadata: {
          runtime_instance_id: runtime_instance.id,
          container_id: container_id,
          container_state: container[:state],
          container_status: container[:status]
        }.compact
      )
      container_id
    end
  end

  def active_container?(container)
    ACTIVE_CONTAINER_STATES.include?(container[:state].to_s.downcase)
  end

  def app_for(container)
    app_id = container.fetch(:labels, {})[RuntimeAgent::LABEL_APP_ID]
    App.find_by(id: app_id)
  end
end
