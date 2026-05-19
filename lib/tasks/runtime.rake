namespace :runtime do
  desc "Remove old stopped platform containers"
  task cleanup: :environment do
    result = RuntimeAgent.build.cleanup_stopped_containers

    if result.success?
      puts "Removed #{result.payload.fetch(:removed_containers).size} runtime containers."
    else
      warn result.error.to_h
      exit 1
    end
  end

  desc "Enqueue idle sleep checks for running apps"
  task idle_sleep: :environment do
    IdleSleepJob.perform_later
    puts "Idle sleep check enqueued."
  end
end
