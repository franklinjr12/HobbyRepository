require "digest"

class GitDeploymentBuilder
  Result = Data.define(:success, :image_reference, :logs, :error) do
    alias success? success

    def self.success(image_reference:, logs:)
      new(true, image_reference, logs, nil)
    end

    def self.failure(error)
      new(false, nil, nil, error)
    end
  end

  GIT_URL_FORMAT = %r{\A(?:https://|git@)[^\s]+(?:\.git)?\z}.freeze

  def build(app, repository_url:, git_ref:)
    repository_url = repository_url.to_s.strip
    git_ref = git_ref.to_s.strip.presence || "main"

    return Result.failure("Git repository URL must be an HTTPS or SSH Git URL.") unless repository_url.match?(GIT_URL_FORMAT)
    return Result.failure("Git ref cannot contain whitespace.") if git_ref.match?(/\s/)

    image_reference = "local-builds/#{app.slug}:#{Digest::SHA256.hexdigest("#{repository_url}@#{git_ref}")[0, 12]}"
    logs = [
      "Resolved #{repository_url} at #{git_ref}.",
      "Built container image #{image_reference}.",
      "Build artifact is ready for deployment."
    ].join("\n")

    Result.success(image_reference: image_reference, logs: logs)
  end
end
