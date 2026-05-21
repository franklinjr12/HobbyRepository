class RuntimeCapacityGuard
  DEFAULT_MAX_RUNNING_APPS = ENV.fetch("PLATFORM_MAX_RUNNING_APPS", 25).to_i

  Result = Data.define(:success, :error, :details) do
    alias success? success

    def self.success(details = {})
      new(true, nil, details)
    end

    def self.failure(error, details = {})
      new(false, error, details)
    end
  end

  def initialize(node:, max_running_apps: DEFAULT_MAX_RUNNING_APPS)
    @node = node
    @max_running_apps = max_running_apps
  end

  def check(app)
    details = capacity_details(app)

    return Result.failure(running_apps_error(details), details) if running_app_limit_exceeded?(details)
    return Result.failure(memory_error(details), details) if memory_capacity_exceeded?(details)
    return Result.failure(cpu_error(details), details) if cpu_capacity_exceeded?(details)

    Result.success(details)
  end

  private

  attr_reader :node, :max_running_apps

  def capacity_details(app)
    running_scope = node.apps.running.where.not(id: app.id)
    reserved_memory_bytes = running_scope.sum(:memory_limit_bytes).to_i
    reserved_cpu = running_scope.sum(:cpu_limit).to_d

    {
      node_id: node.id,
      running_app_count: running_scope.count,
      max_running_apps: max_running_apps,
      reserved_memory_bytes: reserved_memory_bytes,
      requested_memory_bytes: app.memory_limit_bytes.to_i,
      capacity_memory_bytes: node.capacity_memory_bytes,
      reserved_cpu: reserved_cpu,
      requested_cpu: app.cpu_limit.to_d,
      capacity_cpu: node.capacity_cpu
    }
  end

  def running_app_limit_exceeded?(details)
    return false if max_running_apps <= 0

    details.fetch(:running_app_count) + 1 > max_running_apps
  end

  def memory_capacity_exceeded?(details)
    capacity = details.fetch(:capacity_memory_bytes)
    return false if capacity.blank?

    details.fetch(:reserved_memory_bytes) + details.fetch(:requested_memory_bytes) > capacity
  end

  def cpu_capacity_exceeded?(details)
    capacity = details.fetch(:capacity_cpu)
    return false if capacity.blank? || details.fetch(:requested_cpu).zero?

    details.fetch(:reserved_cpu) + details.fetch(:requested_cpu) > capacity
  end

  def running_apps_error(details)
    "Host capacity unavailable: #{details.fetch(:running_app_count)} apps are already running."
  end

  def memory_error(details)
    "Host capacity unavailable: memory reservations would exceed this node's capacity."
  end

  def cpu_error(details)
    "Host capacity unavailable: CPU reservations would exceed this node's capacity."
  end
end
