# frozen_string_literal: true
require 'minitest/autorun'
ENV['AI_GATEWAY_URL'] = 'https://gateway.example.com'
require_relative '../mac/辅助文件/setup'
class MacInstallerTest < Minitest::Test
  def test_runtime_gateway_validation
    assert_equal 'https://other.example.com:8443', ClaudeInstaller.gateway_origin('https://OTHER.example.com:8443/')
    [nil, '', 'http://gateway.example.com', 'https://user@gateway.example.com',
     'https://gateway.example.com/v1', 'https://gateway.example.com?x=1',
     'https://gateway.example.com#f', 'https://gateway.example.com:0',
     'https://gateway.example.com:65536'].each do |value|
      assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.gateway_origin(value) }
    end
  end

  def test_selects_highest_lts_not_latest_current
    rows = [
      { 'version' => 'v28.0.0', 'lts' => false, 'files' => ['osx-x64-pkg'] },
      { 'version' => 'v24.9.0', 'lts' => 'LTS', 'files' => ['osx-x64-pkg'] },
      { 'version' => 'v26.1.0', 'lts' => 'LTS', 'files' => ['osx-x64-pkg'] },
      { 'version' => 'v24.10.0', 'lts' => 'LTS', 'files' => ['osx-x64-pkg'] }
    ]
    assert_equal 'v26.1.0', ClaudeInstaller.latest_lts(rows)
    assert_equal 'v24.10.0', ClaudeInstaller.latest_lts(rows[1..1] + rows[3..3])
  end
  def test_refuses_missing_pkg_and_bad_versions
    assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.latest_lts([]) }
    assert_raises(ClaudeInstaller::Failure) do
      ClaudeInstaller.latest_lts([{ 'version' => '../../bad', 'lts' => 'x', 'files' => ['osx-x64-pkg'] }])
    end
    assert_raises(ClaudeInstaller::Failure) do
      ClaudeInstaller.latest_lts([{ 'version' => 'v26.1.0', 'lts' => 'x', 'files' => ['osx-arm64-tar'] }])
    end
  end
  def test_path_persistence_preserves_existing_bash_profile_and_is_idempotent
    Dir.mktmpdir('claude-path-test-', File.realpath(Dir.tmpdir)) do |temp|
      assert_equal File.expand_path(temp), File.realpath(temp)
      File.write(File.join(temp, '.profile'), "export EXISTING_SETTING=kept\n")
      command_dir = File.join(temp, 'commands with spaces')
      Dir.mkdir(command_dir)
      claude = File.join(command_dir, 'claude')
      File.write(claude, "#!/bin/bash\necho test\n"); File.chmod(0700, claude)
      old_zdotdir = ENV.delete('ZDOTDIR')
      begin
        Dir.stub(:home, temp) do
          ClaudeInstaller.persist_user_bin(claude)
          first = File.read(File.join(temp, '.profile'))
          assert first.start_with?("export EXISTING_SETTING=kept\n")
          refute File.exist?(File.join(temp, '.bash_profile'))
          assert first.include?('Claude company gateway PATH')
          ClaudeInstaller.persist_user_bin(claude)
          assert_equal first, File.read(File.join(temp, '.profile'))
          found, _, status = Open3.capture3({ 'HOME' => temp }, '/bin/bash', '-c', '. "$HOME/.profile"; command -v claude')
          assert status.success?
          assert_equal claude, found.strip
        end
      ensure
        ENV['ZDOTDIR'] = old_zdotdir if old_zdotdir
      end
    end
  end
  def test_usable_node_behind_old_node_is_reused
    Dir.mktmpdir('claude-runtime-test-', File.realpath(Dir.tmpdir)) do |temp|
      assert_equal File.expand_path(temp), File.realpath(temp)
      dirs = ['old', 'new'].map { |name| File.join(temp, name) }
      dirs.each_with_index do |dir, index|
        Dir.mkdir(dir)
        File.write(File.join(dir, 'node'), "#!/bin/sh\necho v#{index.zero? ? 20 : 24}.0.0\n")
        File.write(File.join(dir, 'npm'), "#!/bin/sh\necho 11.0.0\n")
        File.chmod(0700, File.join(dir, 'node'), File.join(dir, 'npm'))
      end
      original = ENV['PATH']
      begin
        ENV['PATH'] = dirs.join(':')
        assert ClaudeInstaller.node_ready?
        assert_equal dirs.last, ENV['PATH'].split(':').first
      ensure
        ENV['PATH'] = original
      end
    end
  end
  def test_sha256_success_failure_and_duplicate
    digest = 'a' * 64
    name = 'node-v26.1.0.pkg'
    text = "#{digest}  #{name}\n"
    ClaudeInstaller.verify_checksum(text, name, digest.upcase)
    assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.verify_checksum(text, name, 'b' * 64) }
    assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.verify_checksum('', name, digest) }
    assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.verify_checksum(text + text, name, digest) }
    assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.verify_checksum("#{digest}  #{name}.other\n", name, digest) }
  end

  Status = Struct.new(:exitstatus, :termsig) do
    def success?; exitstatus == 0; end
  end
  OK = Status.new(0, nil)
  BAD = Status.new(17, nil)

  def isolated
    Dir.mktmpdir('claude-mac-test-', File.realpath(Dir.tmpdir)) do |home|
      original = ENV.delete('CLAUDE_CONFIG_DIR')
      begin
        Dir.stub(:home, home) do
          ClaudeInstaller.instance_variable_set(:@sensitive, [])
          ClaudeInstaller.instance_variable_set(:@state, { node: 'existing', claude: 'existing', configuration: 'unchanged', path: 'unchanged' })
          yield home
        end
      ensure
        ENV['CLAUDE_CONFIG_DIR'] = original if original
      end
    end
  end

  def shared
    File.expand_path('../common/configure.cjs', __dir__)
  end

  def with_stubs(stubs, &block)
    return block.call if stubs.empty?
    method, result = stubs.first
    ClaudeInstaller.stub(method, result) { with_stubs(stubs[1..-1], &block) }
  end

  def run_main(stubs)
    result = nil
    out, err = capture_io do
      Process.stub(:euid, 501) do
        with_stubs([[:supported_platform?, true]] + stubs) { result = ClaudeInstaller.main }
      end
    end
    [result, out, err]
  end

  def write_settings(home, content)
    dir = File.join(home, '.claude')
    Dir.mkdir(dir) unless File.directory?(dir)
    File.binwrite(File.join(dir, 'settings.json'), content)
  end

  def test_preflight_missing_config_does_not_create_directory
    isolated do |home|
      prepared = ClaudeInstaller.preflight(shared)
      assert_nil prepared[:digest]
      assert_equal File.join(home, '.claude', 'settings.json'), prepared[:target]
      refute File.exist?(File.join(home, '.claude'))
    end
  end

  def test_preflight_digest_matches_exact_bytes_and_retains_settings
    isolated do |home|
      bytes = "\xEF\xBB\xBF{\"env\":{},\"custom\":123}\n".b
      write_settings(home, bytes)
      prepared = ClaudeInstaller.preflight(shared)
      assert_equal Digest::SHA256.hexdigest(bytes), prepared[:digest]
      assert_equal 123, prepared[:settings]['custom']
    end
  end

  def test_preflight_rejects_bad_json_shape_duplicates_numbers_and_encoding
    isolated do |home|
      ['{"env":[]}', '[]', '{"x":1,"x":2}', '{"x":{"a":1,"\\u0061":2}}',
       '{"x":9007199254740993}', '{"x":9007199254740992.0}', '{"x":1e400}',
       '{"auth":"PRIVATE_SECRET",}', "\xff".b].each do |bytes|
        write_settings(home, bytes)
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.preflight(shared) }
        refute_includes error.message, 'PRIVATE_SECRET'
        assert_equal bytes.b, File.binread(File.join(home, '.claude', 'settings.json'))
      end
    end
  end

  def test_preflight_rejects_symlink_hardlink_oversized_and_relative_config
    isolated do |home|
      outside = File.join(home, 'outside')
      File.write(outside, '{}')
      Dir.mkdir(File.join(home, '.claude'))
      target = File.join(home, '.claude', 'settings.json')
      File.symlink(outside, target)
      assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.preflight(shared) }
      # Only remove a known file created in this isolated test directory.
      assert_equal File.join(home, '.claude', 'settings.json'), target
      File.unlink(target)
      File.link(outside, target)
      assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.preflight(shared) }
      File.unlink(target)
      File.write(target, ' ' * (ClaudeInstaller::MAX_BYTES + 1))
      assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.preflight(shared) }
      ENV['CLAUDE_CONFIG_DIR'] = 'relative'
      assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.preflight(shared) }
    end
  end

  def test_key_cancel_has_no_install_or_configuration_side_effects
    isolated do |home|
      calls = []
      result, out, err = run_main([
        [:native, lambda { |_script| raise ClaudeInstaller::Cancelled }],
        [:node_ready?, lambda { calls << :node; true }],
        [:ensure_user_bin, lambda { calls << :bin }],
        [:configure_prepared, lambda { |*_args| calls << :save }]
      ])
      assert_equal 0, result
      assert_includes out, '已取消'
      assert_empty err
      assert_empty calls
      assert_empty Dir.children(home)
    end
  end

  def test_blank_key_retries_and_explicit_cancel_still_has_no_side_effects
    isolated do |home|
      calls = 0
      native = lambda { |_script|
        calls += 1
        raise ClaudeInstaller::Cancelled if calls == 3
        calls == 1 ? '   ' : '继续'
      }
      result, _out, err = run_main([[:native, native], [:node_ready?, lambda { flunk 'Node checked before key cancel' }]])
      assert_equal 0, result
      assert_equal 3, calls
      assert_empty err
      assert_empty Dir.children(home)
    end
  end

  def test_bad_configuration_fails_before_key_or_install
    isolated do |home|
      write_settings(home, '{broken')
      dialogs = []
      result, _out, err = run_main([
        [:choose_key, lambda { |_settings| flunk 'key dialog called for broken config' }],
        [:node_ready?, lambda { flunk 'installation checked for broken config' }],
        [:native, lambda { |script| dialogs << script; '关闭' }]
      ])
      assert_equal 1, result
      assert_includes err, 'MAC_JSON_PARSE'
      assert_includes err, 'preflight'
      assert_equal 1, dialogs.size
      assert_includes dialogs.first, '复制诊断信息'
    end
  end

  def test_existing_key_choice_uses_fixed_labels_without_old_key
    isolated do |_home|
      old = 'private-existing-key'
      settings = { 'env' => { 'ANTHROPIC_BASE_URL' => ClaudeInstaller.gateway_origin, 'ANTHROPIC_AUTH_TOKEN' => old } }
      scripts = []
      ClaudeInstaller.stub(:native, lambda { |script| scripts << script; '使用现有密钥' }) do
        assert_equal old, ClaudeInstaller.choose_key(settings)
      end
      assert_equal 1, scripts.size
      %w[使用现有密钥 输入新密钥 取消].each { |label| assert_includes scripts.first, label }
      refute_includes scripts.first, old
    end
  end

  def test_wrong_gateway_does_not_offer_existing_key
    isolated do |_home|
      scripts = []
      settings = { 'env' => { 'ANTHROPIC_BASE_URL' => 'https://gateway.example.com/', 'ANTHROPIC_AUTH_TOKEN' => 'old-token' } }
      ClaudeInstaller.stub(:native, lambda { |script| scripts << script; 'new-token' }) do
        assert_equal 'new-token', ClaudeInstaller.choose_key(settings)
      end
      assert_includes scripts.first, '请输入网关密钥'
      refute_includes scripts.first, '已有'
      refute_includes scripts.first, 'old-token'
    end
  end

  def test_invalid_key_retries_and_native_script_uses_pipe_not_args
    isolated do |_home|
      calls = []
      answers = ['invalid key\n', '继续\n', 'valid-key\n'].map { |s| s.gsub('\\n', "\n") }
      Open3.stub(:capture3, lambda { |*args|
        calls << args
        [answers.shift, '', OK]
      }) do
        assert_equal 'valid-key', ClaudeInstaller.choose_key({})
      end
      assert_equal 3, calls.size
      calls.each do |args|
        assert_equal ['/usr/bin/osascript', '-'], args[0..1]
        assert args.last.key?(:stdin_data)
        refute args[0..-2].any? { |arg| arg.to_s.include?('invalid key') }
      end
      assert_includes calls.last.last[:stdin_data], 'invalid key'
      refute_includes calls.first.last[:stdin_data], 'hidden answer'
    end
  end

  def test_trim_unicode_whitespace_and_retry_script_escape_boundaries
    isolated do |_home|
      refute ClaudeInstaller.valid_key?("inside\u00a0key")
      refute ClaudeInstaller.valid_key?("inside\u2028key")
      refute ClaudeInstaller.valid_key?("inside\x00key")
      input = "invalid\t\\\"key"
      scripts, answers = [], [input, '继续', "\u00a0 final-key \u00a0"]
      ClaudeInstaller.stub(:native, lambda { |script| scripts << script; answers.shift }) do
        assert_equal 'final-key', ClaudeInstaller.choose_key({})
      end
      assert_includes scripts.last, "default answer #{JSON.generate(input)}"
      refute_includes scripts.last, "invalid\t"
    end
  end

  def test_sensitive_collection_keeps_plain_settings_and_json_body_redaction_keeps_details
    isolated do |_home|
      ClaudeInstaller.remember_strings({ 'custom' => 'yes', 'env' => { 'ANTHROPIC_AUTH_TOKEN' => 'private-token' } })
      text = ClaudeInstaller.sanitize('custom yes: permission denied private-token [errno 13]')
      assert_includes text, 'custom yes: permission denied'
      assert_includes text, '[errno 13]'
      refute_includes text, 'private-token'
      text = ClaudeInstaller.sanitize('permission denied {"env":{"secret":"raw-config-value"}} disk full')
      assert_includes text, 'permission denied'
      assert_includes text, 'disk full'
      refute_includes text, 'raw-config-value'
    end
  end

  def test_native_cancel_and_tool_failure_are_distinct_and_stderr_is_not_leaked
    isolated do |_home|
      Open3.stub(:capture3, ['', 'User canceled. (-128)', Status.new(1, nil)]) do
        assert_raises(ClaudeInstaller::Cancelled) { ClaudeInstaller.native('fixed') }
      end
      ClaudeInstaller.instance_variable_set(:@sensitive, ['sensitive-raw-key'])
      Open3.stub(:capture3, ['', 'permission denied sensitive-raw-key', BAD]) do
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.native('fixed') }
        assert_includes error.message, '退出码 17'
        assert_includes error.message, 'permission denied'
        refute_includes error.message, 'sensitive-raw-key'
      end
    end
  end

  def test_prepared_config_uses_only_private_stdin_payload
    isolated do |home|
      prepared = ClaudeInstaller.preflight(shared)
      token = 'private-selected-token'
      response = { ok: true, target: prepared[:target], backup: nil, state: 'saved', warnings: [], verified: false }
      calls = []
      Open3.stub(:capture3, lambda { |*args| calls << args; [JSON.generate(response), '', OK] }) do
        ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, token)
      end
      assert_equal ['/fake/node', shared, '--prepared-stdin'], calls.first[0..2]
      data = JSON.parse(calls.first.last[:stdin_data])
      assert_equal token, data['token']
      assert_nil data['expectedDigest']
      assert_equal prepared[:target], data['target']
      assert_equal 'saved', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
      assert_empty Dir.children(home)
    end
  end

  def test_child_diagnostic_survives_nonzero_with_json_position_and_saving_state
    isolated do |_home|
      prepared = { target: '/fake/settings.json', digest: nil }
      response = { ok: false, diagnostic: { code: 'CFG_CHANGED', stage: 'configure', reason: '保存前文件变化', line: 3, column: 5, state: 'saving' } }
      ClaudeInstaller.instance_variable_set(:@sensitive, ['RAW_SECRET'])
      Open3.stub(:capture3, [JSON.generate(response), 'write access denied RAW_SECRET', BAD]) do
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, 'secret') }
        assert_equal 'CFG_CHANGED', error.code
        assert_equal 3, error.line
        assert_equal 5, error.column
        assert_includes error.message, '退出码 17'
        refute_includes error.message, 'RAW_SECRET'
      end
      assert_equal 'saving', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
    end
  end

  def test_child_invalid_json_and_spawn_exception_are_sanitized
    isolated do |_home|
      token = 'never-display-secret'
      ClaudeInstaller.instance_variable_set(:@sensitive, [token])
      prepared = { target: '/fake/settings.json', digest: nil }
      Open3.stub(:capture3, [token, token, BAD]) do
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, token) }
        assert_equal 'MAC_CONFIG_PROTOCOL', error.code
        assert_equal 'unknown', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
        refute_includes error.message, token
      end
      Open3.stub(:capture3, lambda { |*_args| raise IOError, "private pipe failure #{token}" }) do
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, token) }
        assert_includes error.message, 'IOError'
        assert_includes error.message, 'private pipe failure'
        assert_equal 'unknown', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
        refute_includes error.message, token
      end
    end
  end

  def test_child_metadata_is_whitelisted_and_one_character_key_cannot_mangle_saved
    isolated do |_home|
      ClaudeInstaller.stage('configure')
      prepared = { target: '/fake/settings.json', digest: nil }
      response = { ok: false, diagnostic: { code: 'arbitrary code', stage: 'arbitrary stage', reason: 'disk problem', line: '3', column: -1, state: 'arbitrary state' } }
      Open3.stub(:capture3, [JSON.generate(response), '', BAD]) do
        error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, 's') }
        assert_equal 'MAC_CONFIG_CHILD', error.code
        assert_nil error.line
        assert_nil error.column
      end
      assert_equal 'unknown', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
      assert_equal 'configure', ClaudeInstaller.instance_variable_get(:@stage)
      ClaudeInstaller.instance_variable_set(:@sensitive, ['s'])
      ClaudeInstaller.instance_variable_get(:@state)[:configuration] = 'saved'
      ClaudeInstaller.stage('save')
      ClaudeInstaller.stub(:native, '关闭') do
        _out, err = capture_io { ClaudeInstaller.report_failure(ClaudeInstaller::Failure.new('disk problem', 'MAC_DISK')) }
        assert_includes err, '错误编号：MAC_DISK'
        assert_includes err, '阶段：save'
        assert_includes err, '配置保存：saved'
      end
    end
  end

  def test_success_wrong_target_keeps_configuration_unknown
    isolated do |_home|
      prepared = { target: '/fake/settings.json', digest: nil }
      response = { ok: true, target: '/other/settings.json', state: 'saved', warnings: [], verified: false }
      Open3.stub(:capture3, [JSON.generate(response), '', OK]) do
        assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.configure_prepared('/fake/node', shared, prepared, 'test-key') }
      end
      assert_equal 'unknown', ClaudeInstaller.instance_variable_get(:@state)[:configuration]
    end
  end

  def normal_stubs(events, path_action = nil)
    [[:choose_key, lambda { |_settings| events << :key; 'private-test-key' }],
     [:node_ready?, lambda { events << :node; true }],
     [:executable, lambda { |name| '/fake/' + name }],
     [:capture_tool, lambda { |*_args| ['', OK] }],
     [:ensure_user_bin, lambda { flunk 'existing software must not create bin' }],
     [:install_node, lambda { flunk 'unexpected Node installation' }],
     [:install_claude, lambda { |_bin| flunk 'unexpected Claude installation' }],
     [:configure_prepared, lambda { |_node, _shared, _prepared, _token|
       events << :save
       ClaudeInstaller.instance_variable_get(:@state)[:configuration] = 'saved'
       { 'ok' => true }
     }],
     [:persist_user_bin, path_action || lambda { |_claude| events << :path }]]
  end

  def test_key_only_normal_flow_has_no_install_confirmation_or_extra_success_pause
    isolated do |home|
      events = []
      result, out, err = run_main(normal_stubs(events) + [[:native, lambda { |_script| flunk 'unexpected native installation confirmation' }]])
      assert_equal 0, result
      assert_equal [:key, :node, :save, :path], events
      assert_empty err
      assert_includes out, '配置已保存，未验证网关密钥或模型。'
      assert_includes out, '配置完成。请在项目目录打开新终端，运行 claude。'
      refute_includes out, '回车'
      assert_empty Dir.children(home)
    end
  end

  def test_install_confirmation_is_after_key_and_cancel_has_no_side_effects
    isolated do |home|
      events = []
      result, _out, err = run_main([
        [:choose_key, lambda { |_settings| events << :key; 'selected-key' }],
        [:node_ready?, lambda { events << :node; false }],
        [:executable, nil],
        [:native, lambda { |_script| events << :confirm; raise ClaudeInstaller::Cancelled }],
        [:install_node, lambda { flunk 'installed after cancel' }],
        [:ensure_user_bin, lambda { flunk 'created bin after cancel' }]
      ])
      assert_equal 0, result
      assert_equal [:key, :node, :confirm], events
      assert_empty err
      assert_empty Dir.children(home)
    end
  end

  def test_saved_configuration_with_path_failure_has_truthful_partial_state_and_copy_dialog
    isolated do |_home|
      events, dialogs = [], []
      fail_path = lambda { |_claude|
        ClaudeInstaller.instance_variable_get(:@state)[:path] = 'partial'
        raise ClaudeInstaller::Failure.new('第二个终端配置无写入权限', 'MAC_PATH_WRITE')
      }
      result, _out, err = run_main(normal_stubs(events, fail_path) + [[:native, lambda { |script| dialogs << script; '关闭' }]])
      assert_equal 1, result
      assert_includes err, 'MAC_PATH_WRITE'
      assert_includes err, '阶段：path'
      assert_includes err, '配置保存：saved'
      assert_includes err, 'PATH：partial'
      assert_includes err, '第二个终端配置无写入权限'
      assert_equal 1, dialogs.size
      assert_includes dialogs.first, '复制诊断信息'
      assert_includes dialogs.first, 'set the clipboard to diagnosticText'
    end
  end

  def test_unknown_error_has_concrete_class_message_and_redacts_key
    isolated do |_home|
      dialogs = []
      fail_path = lambda { |_claude| raise IOError, 'disk write failed private-test-key' }
      result, _out, err = run_main(normal_stubs([], fail_path) + [[:native, lambda { |script| dialogs << script; '关闭' }]])
      assert_equal 1, result
      assert_includes err, 'MAC_UNEXPECTED'
      assert_includes err, 'IOError'
      assert_includes err, 'disk write failed'
      refute_includes err, 'private-test-key'
      refute_includes dialogs.first, 'private-test-key'
    end
  end

  def test_real_path_partial_failure_preserves_first_write_and_original_profile
    isolated do |home|
      old_zdotdir = ENV.delete('ZDOTDIR')
      begin
        original_profile = File.join(home, 'original-profile')
        File.write(original_profile, "KEEP_ME=1\n")
        File.symlink(original_profile, File.join(home, '.profile'))
        ClaudeInstaller.stub(:executable, '/fake/node') do
          error = assert_raises(ClaudeInstaller::Failure) { ClaudeInstaller.persist_user_bin('/fake/claude') }
          assert_includes error.message, '链接'
        end
        assert File.read(File.join(home, '.zshrc')).include?('Claude company gateway PATH')
        assert_equal "KEEP_ME=1\n", File.read(original_profile)
        assert_equal 'partial', ClaudeInstaller.instance_variable_get(:@state)[:path]
      ensure
        ENV['ZDOTDIR'] = old_zdotdir if old_zdotdir
      end
    end
  end

  def test_diagnostic_copy_and_close_are_native_and_never_put_body_in_arguments
    isolated do |_home|
      ClaudeInstaller.stage('configure')
      calls = []
      Open3.stub(:capture3, lambda { |*args| calls << args; ['复制诊断信息', '', OK] }) do
        capture_io { assert_equal 1, ClaudeInstaller.report_failure(ClaudeInstaller::Failure.new('磁盘空间不足', 'MAC_DISK')) }
      end
      assert_equal ['/usr/bin/osascript', '-'], calls.first[0..1]
      assert_includes calls.first.last[:stdin_data], 'set the clipboard to diagnosticText'
      assert_includes calls.first.last[:stdin_data], '关闭'
    end
  end
end

class MacDiagnosticVariantTest < Minitest::Test
  def test_literal_json_and_url_credential_variants_are_redacted
    key = 'fixture-quote"-slash\\-private'
    ClaudeInstaller.instance_variable_set(:@sensitive, [key])
    variants = [key, JSON.generate(key)[1...-1], URI.encode_www_form_component(key)]
    variants.each do |value|
      diagnostic = ClaudeInstaller.sanitize("permission denied [errno 13]: #{value}")
      refute_includes diagnostic, value
      assert_includes diagnostic, 'permission denied [errno 13]'
    end
  ensure
    ClaudeInstaller.instance_variable_set(:@sensitive, [])
  end
end
