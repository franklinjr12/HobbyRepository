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
end
