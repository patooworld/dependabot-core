# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/file_fetcher_command"
require "tmpdir"

RSpec.describe Dependabot::FileFetcherCommand do
  subject(:job) { described_class.new }

  let(:api_client) { double(Dependabot::ApiClient) }
  let(:job_id) { "123123" }

  before do
    allow(Dependabot::Environment).to receive(:job_id).and_return(job_id)
    allow(Dependabot::Environment).to receive(:job_token).and_return("job_token")
    allow(Dependabot::ApiClient).to receive(:new).and_return(api_client)

    allow(api_client).to receive(:mark_job_as_processed)
    allow(api_client).to receive(:record_update_job_error)
    allow(api_client).to receive(:record_ecosystem_versions)
    allow(api_client).to receive(:is_a?).with(Dependabot::ApiClient).and_return(true)

    allow(Dependabot::Environment).to receive(:output_path).and_return(File.join(Dir.mktmpdir, "output.json"))
    allow(Dependabot::Environment).to receive(:job_definition).and_return(job_definition)
  end

  describe "#perform_job" do
    subject(:perform_job) { job.perform_job }

    let(:job_definition) do
      JSON.parse(fixture("jobs/job_with_credentials.json"))
    end

    after do
      # The job definition in this context loads an experiment, so reset it
      Dependabot::Experiments.reset!
    end

    it "fetches the files and writes the fetched files to output.json", vcr: true do
      expect(api_client).not_to receive(:mark_job_as_processed)

      perform_job

      output = JSON.parse(File.read(Dependabot::Environment.output_path))
      dependency_file = output["base64_dependency_files"][0]
      expect(dependency_file["name"]).to eq(
        "dependabot-test-ruby-package.gemspec"
      )
      expect(dependency_file["content_encoding"]).to eq("utf-8")
    end

    it "does not clone the repo", vcr: true do
      expect_any_instance_of(Dependabot::Bundler::FileFetcher)
        .not_to receive(:clone_repo_contents)

      expect(api_client).not_to receive(:mark_job_as_processed)

      perform_job
    end

    context "when the fetcher raises a ToolVersionNotSupported error", vcr: true do
      before do
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit).and_return("a" * 40)
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:files).and_return([])
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:ecosystem_versions)
          .and_raise(Dependabot::ToolVersionNotSupported.new("Bundler", "1.7", "2.x"))
      end

      it "tells the backend about the error (and doesn't re-raise it)" do
        expect(api_client)
          .to receive(:record_update_job_error)
          .with(
            error_details: { "tool-name": "Bundler", "detected-version": "1.7", "supported-versions": "2.x" },
            error_type: "tool_version_not_supported"
          )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end
    end

    context "when the fetcher raises a BranchNotFound error" do
      before do
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit)
          .and_raise(Dependabot::BranchNotFound, "my_branch")
      end

      it "tells the backend about the error (and doesn't re-raise it)" do
        expect(api_client)
          .to receive(:record_update_job_error)
          .with(
            error_details: { "branch-name": "my_branch" },
            error_type: "branch_not_found"
          )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end
    end

    context "when the fetcher raises a RepoNotFound error" do
      let(:provider) { job_definition.dig("job", "source", "provider") }
      let(:repo) { job_definition.dig("job", "source", "repo") }
      let(:source) { ::Dependabot::Source.new(provider: provider, repo: repo) }

      before do
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit)
          .and_raise(Dependabot::RepoNotFound, source)
      end

      it "tells the backend about the error (and doesn't re-raise it)" do
        expect(api_client)
          .to receive(:record_update_job_error)
          .with(
            error_details: { message: "Dependabot::RepoNotFound" },
            error_type: "job_repo_not_found"
          )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end
    end

    context "when the fetcher raises a file fetcher error (cloud) ", vcr: true do
      before do
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit)
          .and_raise(StandardError, "my_branch")
        allow(Dependabot::Experiments).to receive(:enabled?).with(:record_update_job_unknown_error).and_return(true)
      end

      it "tells the backend about the error via update job error api (and doesn't re-raise it)" do
        expect(api_client).to receive(:record_update_job_error).with(
          error_type: "file_fetcher_error",
          error_details: {
            "error-backtrace" => an_instance_of(String),
            "error-message" => "my_branch",
            "error-class" => "StandardError",
            "package-manager" => "bundler",
            "job-id" => "123123",
            "job-dependency_group" => []
          }
        )
        expect(api_client).to receive(:record_update_job_unknown_error)
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end

      it "tells the backend about the error via update job unknown error (and doesn't re-raise it)" do
        expect(api_client).to receive(:record_update_job_unknown_error).with(
          error_type: "file_fetcher_error",
          error_details: {
            "error-backtrace" => an_instance_of(String),
            "error-message" => "my_branch",
            "error-class" => "StandardError",
            "package-manager" => "bundler",
            "job-id" => "123123",
            "job-dependency_group" => []
          }
        )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end
    end

    context "when the fetcher raises a file fetcher error (ghes) ", vcr: true do
      before do
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit)
          .and_raise(StandardError, "my_branch")
        allow(Dependabot::Experiments).to receive(:enabled?).with(:record_update_job_unknown_error).and_return(false)
      end

      it "tells the backend about the error via update job error api (and doesn't re-raise it)" do
        expect(api_client).to receive(:record_update_job_error).with(
          error_type: "file_fetcher_error",
          error_details: {
            "error-backtrace" => an_instance_of(String),
            "error-message" => "my_branch",
            "error-class" => "StandardError",
            "package-manager" => "bundler",
            "job-id" => "123123",
            "job-dependency_group" => []
          }
        )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end

      it "do not tells the backend about the error" do
        expect(api_client).to_not receive(:record_update_job_unknown_error)
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
      end
    end

    context "when the fetcher raises a rate limited error" do
      let(:reset_at) { Time.now + 30 }

      before do
        exception = Octokit::TooManyRequests.new(
          response_headers: {
            "X-RateLimit-Reset" => reset_at
          }
        )
        allow_any_instance_of(Dependabot::Bundler::FileFetcher)
          .to receive(:commit)
          .and_raise(exception)
      end

      it "retries the job when the rate-limit is reset and reports api error" do
        expect(Raven).not_to receive(:capture_exception)
        expect(api_client)
          .to receive(:record_update_job_error)
          .with(
            error_details: { "rate-limit-reset": reset_at },
            error_type: "octokit_rate_limited"
          )
        expect(api_client).to receive(:mark_job_as_processed)

        expect { perform_job }.to output(/Repository is rate limited, attempting to retry/).to_stdout_from_any_process
      end
    end

    context "when vendoring dependencies", vcr: true do
      let(:job_definition) do
        JSON.parse(fixture("jobs/job_with_vendor_dependencies.json"))
      end

      before do
        allow(Dependabot::Environment).to receive(:repo_contents_path).and_return(Dir.mktmpdir)
      end

      it "clones the repo" do
        expect(api_client).not_to receive(:mark_job_as_processed)

        perform_job

        root_dir_entries = Dir.entries(Dependabot::Environment.repo_contents_path)
        expect(root_dir_entries).to include(".gitignore")
        expect(root_dir_entries).to include(
          "dependabot-test-ruby-package.gemspec"
        )
        expect(root_dir_entries).to include("README.md")
      end
    end

    context "when package ecosystem always clones", vcr: true do
      let(:job_definition) do
        JSON.parse(fixture("jobs/job_with_go_modules.json"))
      end

      before do
        allow(Dependabot::Environment).to receive(:repo_contents_path).and_return(Dir.mktmpdir)
      end

      it "clones the repo" do
        expect(api_client).not_to receive(:mark_job_as_processed)

        perform_job

        root_dir_entries = Dir.entries(Dependabot::Environment.repo_contents_path)
        expect(root_dir_entries).to include("go.mod")
        expect(root_dir_entries).to include("go.sum")
        expect(root_dir_entries).to include("main.go")
      end

      context "when the fetcher raises a BranchNotFound error while cloning" do
        before do
          allow_any_instance_of(Dependabot::GoModules::FileFetcher)
            .to receive(:clone_repo_contents)
            .and_raise(Dependabot::BranchNotFound, "my_branch")
        end

        it "tells the backend about the error (and doesn't re-raise it)" do
          expect(api_client)
            .to receive(:record_update_job_error)
            .with(
              error_details: { "branch-name": "my_branch" },
              error_type: "branch_not_found"
            )
          expect(api_client).to receive(:mark_job_as_processed)

          expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
        end
      end

      context "when the fetcher raises a OutOfDisk error while cloning" do
        before do
          allow_any_instance_of(Dependabot::GoModules::FileFetcher)
            .to receive(:clone_repo_contents)
            .and_raise(Dependabot::OutOfDisk)
        end

        it "tells the backend about the error (and doesn't re-raise it)" do
          expect(api_client)
            .to receive(:record_update_job_error)
            .with(
              error_details: {},
              error_type: "out_of_disk"
            )
          expect(api_client).to receive(:mark_job_as_processed)

          expect { perform_job }.to output(/Error during file fetching; aborting/).to_stdout_from_any_process
        end
      end
    end

    context "when the connectivity check is enabled", vcr: true do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ENABLE_CONNECTIVITY_CHECK").and_return("1")
      end

      it "logs connectivity is successful and does not raise an error" do
        expect(Dependabot.logger).to receive(:info).with(/Connectivity check starting/)
        expect(Dependabot.logger).to receive(:info).with(/Connectivity check successful/)

        expect { perform_job }.not_to raise_error
      end

      context "when connectivity is broken" do
        let(:mock_octokit) { instance_double(Octokit::Client) }

        before do
          allow(Octokit::Client)
            .to receive(:new)
            .and_call_original
          allow(Octokit::Client)
            .to receive(:new).with({
              api_endpoint: "https://api.github.com/",
              connection_options: {
                request: {
                  open_timeout: 20,
                  timeout: 5
                }
              }
            })
                             .and_return(mock_octokit)
          allow(mock_octokit).to receive(:repository)
            .and_raise(Octokit::Error)
        end

        it "logs connectivity failed and does not raise an error" do
          expect(Dependabot.logger).to receive(:info).with(/Connectivity check starting/)
          expect(Dependabot.logger).to receive(:error).with(/Connectivity check failed/)

          expect { perform_job }.not_to raise_error
        end
      end
    end

    context "when job contains multi-directory ", vcr: true do
      let(:job_definition) do
        job_definition_fixture("bundler/security_updates/group_update_multi_dir")
      end

      it "fetches the files and writes the fetched files to output.json for all directories" do
        expect(api_client).not_to receive(:mark_job_as_processed)

        perform_job

        expected_files = [
          { "directory" => "/bar", "name" => "Gemfile", "content_encoding" => "utf-8" },
          { "directory" => "/bar", "name" => "Gemfile.lock", "content_encoding" => "utf-8" },
          { "directory" => "/foo", "name" => "Gemfile", "content_encoding" => "utf-8" },
          { "directory" => "/foo", "name" => "Gemfile.lock", "content_encoding" => "utf-8" }
        ]

        output = JSON.parse(File.read(Dependabot::Environment.output_path))
        output["base64_dependency_files"].each do |dependency_file|
          expected_file = expected_files.find do |ef|
            ef["directory"] == dependency_file["directory"] && ef["name"] == dependency_file["name"]
          end

          error_message = "Unexpected file #{dependency_file['name']} found in directory " \
                          "#{dependency_file['directory']}"
          expect(expected_file).not_to be_nil, error_message

          expected_file.each do |key, value|
            error_message = "Expected #{key} to be #{value} for file #{dependency_file['name']} in " \
                            "#{dependency_file['directory']}, but got #{dependency_file[key]}"
            expect(dependency_file[key]).to eq(value), error_message
          end
        end
      end
    end
  end
end
