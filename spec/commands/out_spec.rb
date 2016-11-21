require 'json'
require 'tmpdir'
require 'webmock/rspec'
require_relative '../../assets/lib/commands/out'

describe Commands::Out do
  let(:dest_dir) { Dir.mktmpdir }

  def git(cmd, dir = dest_dir)
    Dir.chdir(dir) { `git #{cmd}`.chomp }
  end

  def commit(msg)
    git("-c user.name='test' -c user.email='test@example.com' commit -q --allow-empty -m '#{msg}'")
    git('log --format=format:%H HEAD')
  end

  def put(payload)
    payload['source']['no_ssl_verify'] = true

    resource_dir = Dir.mktmpdir
    FileUtils.cp_r(dest_dir, File.join(resource_dir, 'resource'))

    command = Commands::Out.new(input: payload, destination: resource_dir)
    command.output
  end

  def stub_status_post
    stub_request(:post, "https://api.github.com:443/repos/jtarchie/test/statuses/#{@sha}")
  end

  before do
    git('init -q')

    @sha = commit('test commit')

    stub_json(:get, "https://api.github.com:443/repos/jtarchie/test/statuses/#{@sha}", [])
    ENV['BUILD_ID'] = '1234'
  end

  def stub_json(method, uri, body)
    stub_request(method, uri)
      .to_return(headers: { 'Content-Type' => 'application/json' }, body: body.to_json)
  end

  context 'when the git repo has no pull request meta information' do
    it 'sets the status just on the SHA' do
      stub_status_post

      output = put('params' => { 'status' => 'pending', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
      expect(output).to eq('version'  => { 'ref' => @sha },
                           'metadata' => [
                             { 'name' => 'status', 'value' => 'pending' }
                           ])
    end
  end

  context 'when the git repo has the pull request meta information' do
    before do
      git('config --add pullrequest.id 1')
      stub_json(:get, 'https://api.github.com:443/repos/jtarchie/test/pulls/1',
                html_url: 'http://example.com',
                number: 1,
                head: { sha: 'abcdef' })
    end

    context 'when setting a status with a comment' do
      before do
        File.write(File.join(dest_dir, 'comment'), 'comment message')
      end

      it 'posts a comment to the PR\'s SHA' do
        stub_status_post
        stub_json(:post, 'https://api.github.com:443/repos/jtarchie/test/issues/1/comments', id: 1)

        output, = put('params' => { 'status' => 'success', 'path' => 'resource', 'comment' => 'resource/comment' }, 'source' => { 'repo' => 'jtarchie/test' })
        expect(output).to eq('version'  => { 'ref' => @sha, 'pr' => '1' },
                             'metadata' => [
                               { 'name' => 'status', 'value' => 'success' },
                               { 'name' => 'url', 'value' => 'http://example.com' }
                             ])
      end

      context 'when the message file does not exist' do
        it 'returns a helpful error message' do
          expect do
            put('params' => { 'status' => 'success', 'path' => 'resource', 'comment' => 'resource/comment-doesnt-exist' }, 'source' => { 'repo' => 'jtarchie/test' })
          end.to raise_error '`comment` "resource/comment-doesnt-exist" does not exist'
        end
      end
    end

    context 'when acquiring a pull request' do
      it 'sets into pending mode' do
        stub_status_post

        output = put('params' => { 'status' => 'pending', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
        expect(output).to eq('version'  => { 'ref' => @sha, 'pr' => '1' },
                             'metadata' => [
                               { 'name' => 'status', 'value' => 'pending' },
                               { 'name' => 'url', 'value' => 'http://example.com' }
                             ])
      end

      context 'with bad params' do
        it 'raises an error when path is missing' do
          expect do
            put('params' => { 'status' => 'pending' }, 'source' => { 'repo' => 'jtarchie/test' })
          end.to raise_error '`path` required in `params`'
        end

        it 'raises an error when the path does not exist' do
          expect do
            put('params' => { 'status' => 'pending', 'path' => 'do not care' }, 'source' => { 'repo' => 'jtarchie/test' })
          end.to raise_error '`path` "do not care" does not exist'
        end

        context 'with unsupported statuses' do
          it 'raises an error the supported ones' do
            expect do
              put('params' => { 'status' => 'do not care', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
            end.to raise_error '`status` "do not care" is not supported -- only success, failure, error, or pending'
          end
        end
      end
    end

    context 'when the pull request is being release' do
      context 'and the build passed' do
        it 'sets into success mode' do
          stub_status_post

          output = put('params' => { 'status' => 'success', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
          expect(output).to eq('version'  => { 'ref' => @sha, 'pr' => '1' },
                               'metadata' => [
                                 { 'name' => 'status', 'value' => 'success' },
                                 { 'name' => 'url', 'value' => 'http://example.com' }
                               ])
        end

        context 'with base_url defined on source' do
          it 'sets the target_url for status' do
            stub_status_post.with(body: hash_including('target_url' => 'http://example.com/builds/1234'))

            put('params' => { 'status' => 'success', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test', 'base_url' => 'http://example.com' })
          end
        end

        context 'with no base_url defined, but with ATC_EXTERNAL_URL defined' do
          it 'sets the target_url for status' do
            ENV['ATC_EXTERNAL_URL'] = 'http://atc-endpoint.com'
            stub_status_post.with(body: hash_including('target_url' => 'http://atc-endpoint.com/builds/1234'))

            put('params' => { 'status' => 'success', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
          end
        end

        it 'sets the a default context on the status' do
          stub_status_post.with(body: hash_including('context' => 'concourse-ci/status'))

          put('params' => { 'status' => 'success', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
        end

        context 'with a custom context for the status' do
          it 'sets the context' do
            stub_status_post.with(body: hash_including('context' => 'concourse-ci/my-custom-context'))

            put('params' => { 'status' => 'success', 'path' => 'resource', 'context' => 'my-custom-context' }, 'source' => { 'repo' => 'jtarchie/test' })
          end
        end
      end

      context 'and the build failed' do
        it 'sets into failure mode' do
          stub_status_post

          output, = put('params' => { 'status' => 'failure', 'path' => 'resource' }, 'source' => { 'repo' => 'jtarchie/test' })
          expect(output).to eq('version'  => { 'ref' => @sha, 'pr' => '1' },
                               'metadata' => [
                                 { 'name' => 'status', 'value' => 'failure' },
                                 { 'name' => 'url', 'value' => 'http://example.com' }
                               ])
        end
      end
    end
  end
end
