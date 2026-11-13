#!/usr/bin/ruby
# Isolated tests only: no GUI, real home, app launch, or network.
require 'minitest/autorun'
ENV['AI_GATEWAY_URL'] = 'https://gateway.example.com'
require 'tmpdir'
require_relative 'codex_setup'

class SetupTest < Minitest::Test
  S = CodexSetup
  def test_runtime_gateway_validation
    assert_equal 'https://other.example.com:8443', S.gateway_origin('https://OTHER.example.com:8443/')
    [nil, '', 'http://gateway.example.com', 'https://user@gateway.example.com',
     'https://gateway.example.com/v1', 'https://gateway.example.com?x=1',
     'https://gateway.example.com#f', 'https://gateway.example.com:0',
     'https://gateway.example.com:65536'].each do |value|
      assert_raises(S::Unsafe) { S.gateway_origin(value) }
    end
  end

  def test_custom_gateway_render_and_reuse
    previous = ENV['AI_GATEWAY_URL']
    ENV['AI_GATEWAY_URL'] = 'https://other.example.com:8443/'
    document = S::Document.new('')
    rendered = S::Document.new(document.render('synthetic-key'))
    assert_equal 'https://other.example.com:8443/v1', rendered.entries[%w[model_providers custom base_url]]
    assert S.reusable?(rendered)
    old = S::Document.new("[model_providers.custom]\nbase_url = 'https://gateway.example.com/v1'\nexperimental_bearer_token = 'synthetic-old'\n")
    refute S.reusable?(old)
  ensure
    ENV['AI_GATEWAY_URL'] = previous
  end

  def test_preserve_and_escape
    original = <<~TOML
      # [model_providers.custom] is just a comment
      model = 'existing-model'
      approval_policy = "never" # keep this
      [plugins."codex-app-tools@openai-bundled"]
      enabled = true
      [projects."/Users/a/foo"]
      trust_level = "trusted"
      [model_providers.custom]
      name = 'old' # keep comment
      base_url = 'https://gateway.example.com/v1/'
      experimental_bearer_token = 'old-key'
    TOML
    d = S::Document.new(original)
    assert S.reusable?(d)
    secret = "quote\" slash\\ newline\n tab\t 中文 \u0001"
    result = d.render(secret)
    parsed = S::Document.new(result)
    assert_equal secret, parsed.entries[%w[model_providers custom experimental_bearer_token]]
    assert_equal 'existing-model', parsed.entries[['model']]
    assert_includes result, '[plugins."codex-app-tools@openai-bundled"]'
    assert_includes result, '[projects."/Users/a/foo"]'
    assert_includes result, 'approval_policy = "never" # keep this'
    assert_includes result, 'name = "custom" # keep comment'
    assert_equal false, result.include?("\u0001")
  end

  def test_new_file_defaults
    d = S::Document.new('')
    p = S::Document.new(d.render('secret'))
    assert_equal 'gpt-6.1-sol', p.entries[['model']]
    assert_equal 'custom', p.entries[['model_provider']]
    assert_equal 'responses', p.entries[%w[model_providers custom wire_api]]
    assert_equal :scalar, p.entries[%w[model_providers custom requires_openai_auth]]
    assert_equal S.gateway_url, p.entries[%w[model_providers custom base_url]]
  end

  def test_url_key_reuse
    good = ['https://gateway.example.com', 'https://gateway.example.com/', 'https://gateway.example.com/v1', 'https://gateway.example.com/v1/']
    bad = ['http://gateway.example.com/v1', 'https://gateway.example.com.evil/v1', 'https://gateway.example.com/v2', 'https://gateway.example.com/v1?x=1', 'https://user@gateway.example.com/v1', 'https://gateway.example.com:444/v1']
    (good + bad).each do |url|
      d = S::Document.new("[model_providers.custom]\nbase_url = #{S.toml_string(url)}\nexperimental_bearer_token = 'key'\n")
      assert_equal good.include?(url), S.reusable?(d), url
    end
    d = S::Document.new("[model_providers.custom]\nbase_url = 'https://gateway.example.com/v1'\nexperimental_bearer_token = ''\n")
    refute S.reusable?(d)
  end

  def test_unsupported_or_duplicate_toml_rejected
    invalid = [
      "model = '''hello\nworld'''\n", "model = \"\"\"hello\nworld\"\"\"\n",
      "model_provider = 'a'\nmodel_provider = 'b'\n", "[a]\nx = 1\n[a]\ny = 2\n",
      "model_providers.custom.base_url = 'x'\n", "x = { a = 1 }\n", "[[a]]\nx = 1\n",
      "[model_providers.custom]\nx = 1\n[model_providers.custom]\ny = 2\n",
      "model_providers = 'x'\n", "model_providers = 1\n[model_providers.custom]\nx = 1\n",
      "x = 01\n", "model = 123\n", "x = 'ok' junk\n", "# invalid\x01\n"
    ]
    invalid.each { |input| assert_raises(S::Unsafe, input.inspect) { S::Document.new(input) } }
  end

  def test_backup_atomic_permissions_and_stale_guard
    Dir.mktmpdir('codex-test-', File.dirname(__FILE__)) do |dir|
      path = File.join(dir, 'config.toml')
      original = "model = 'old'\n"
      File.write(path, original)
      data, stat = S.read_config(path)
      result = S::Document.new(data).render('my-key')
      backup = S.save_config(dir, data, stat, result)
      assert_equal original, File.read(backup)
      assert_equal 0, File.stat(backup).mode & 077
      assert_equal 0, File.stat(path).mode & 077
      assert_equal result, File.read(path)
      old, old_stat = S.read_config(path)
      File.write(path, "changed = true\n")
      assert_raises(S::Unsafe) { S.save_config(dir, old, old_stat, result) }
      assert_equal "changed = true\n", File.read(path)
      File.unlink(path)
      File.symlink(backup, path)
      assert_raises(S::Unsafe) { S.read_config(path) }
    end
  end

  def test_atomic_new_config_does_not_overwrite_existing
    Dir.mktmpdir('codex-test-', File.dirname(__FILE__)) do |dir|
      rendered = S::Document.new('').render('new-key')
      path = File.join(dir, 'config.toml')
      assert_nil S.save_config(dir, '', nil, rendered)
      assert_equal rendered, File.read(path)
      assert_raises(Errno::EEXIST) { S.save_config(dir, '', nil, rendered) }
      assert_equal rendered, File.read(path)
    end
  end

  def test_unsafe_directory_rejected
    Dir.mktmpdir('codex-test-', File.dirname(__FILE__)) do |dir|
      File.chmod(0777, dir)
      assert_raises(S::Unsafe) { S.safe_directory(dir) }
      File.chmod(0700, dir)
      link = File.join(dir, 'link')
      File.symlink(dir, link)
      assert_raises(S::Unsafe) { S.safe_directory(link) }
    end
  end

  def test_parse_diagnostics_include_line_and_precise_reason
    cases = {
      "# comment\nx = { a = 1 }\n" => '内联表',
      "# comment\n[[a]]\n" => '数组表',
      "# comment\nx = 1\nx = 2\n" => '重复',
      "# comment\nx = \"\"\"text\n" => '多行字符串',
      "# comment\na.b = 1\n" => '点分',
      "# comment\nmodel = 123\n" => 'model',
      "# comment\nmodel_providers = 1\n" => '网关分组'
    }
    cases.each do |text, reason|
      error = assert_raises(S::Unsafe) { S::Document.new(text) }
      assert_includes error.message, reason
      assert_equal(reason == '重复' ? 3 : 2, error.line)
      notice = S.diagnostic_text('parse', error, :unchanged)
      assert_includes notice, 'CFG-PARSE-001'
      assert_includes notice, "第 #{error.line} 行"
      assert_includes notice, '配置文件未修改'
      refute_includes notice, 'CODEX_HOME'
    end
    error = assert_raises(S::Unsafe) { S::Document.new("\xFF".force_encoding('UTF-8')) }
    assert_includes error.message, 'UTF-8'
    error = assert_raises(S::Unsafe) { S::Document.new("\uFEFFx = 1\n") }
    assert_includes error.message, 'BOM'
  end

  def test_existing_key_requires_confirmation_and_can_be_replaced
    document = S::Document.new("[model_providers.custom]\nbase_url = '#{S.gateway_url}'\nexperimental_bearer_token = 'old-key'\n")
    prompts = []
    S.stub(:dialog, lambda { |text, *args, **opts| prompts << [text, args, opts]; '使用现有密钥' }) do
      assert_equal 'old-key', S.choose_token(document)
    end
    assert_equal 1, prompts.length
    assert_equal '检测到已有网关密钥，是否使用？', prompts[0][0]
    refute_includes prompts[0][0], 'old-key'
    prompts.clear
    answers = ['输入新密钥', 'replacement-key']
    S.stub(:dialog, lambda { |text, *args, **opts| prompts << [text, args, opts]; answers.shift }) do
      assert_equal 'replacement-key', S.choose_token(document)
    end
    assert_equal 2, prompts.length
    assert_equal '请输入网关密钥', prompts.last[0]
    assert_equal true, prompts.last[2][:input]
    S.stub(:dialog, '取消') { assert_raises(S::Cancelled) { S.choose_token(document) } }
    S.stub(:dialog, '  ') { assert_raises(S::Cancelled) { S.choose_token(S::Document.new('')) } }
  end

  def test_key_dialog_is_visible_input
    captured = nil
    fake_status = Struct.new(:success?).new(true)
    Open3.stub(:capture3, lambda { |*args, **opts| captured = [args, opts]; ["synthetic-key\n", '', fake_status] }) do
      assert_equal 'synthetic-key', S.dialog('请输入网关密钥', ['取消', '确定'], '确定', input: true)
    end
    assert_includes captured[1][:stdin_data], 'default answer ""'
    refute_includes captured[1][:stdin_data], 'hidden answer'
    refute_includes captured[0].join(' '), 'synthetic-key'
  end

  def test_dialog_escapes_diagnostic_paths_and_control_characters
    captured = nil
    fake_status = Struct.new(:success?).new(true)
    Open3.stub(:capture3, lambda { |*args, **opts| captured = opts[:stdin_data]; ['关闭', '', fake_status] }) do
      S.dialog("path C:\\example\\file \"quoted\"\nnext\ttab\rreturn")
    end
    assert_includes captured, 'C:\\\\example\\\\file'
    assert_includes captured, '\\"quoted\\"'
    assert_includes captured, '\\nnext\\ttab\\rreturn'
  end

  def test_clipboard_receives_diagnostic_via_stdin
    answers = ['复制诊断信息', '关闭']
    captured = nil
    fake_status = Struct.new(:success?).new(true)
    S.stub(:dialog, lambda { |*args| answers.shift }) do
      Open3.stub(:capture3, lambda { |*args, **opts| captured = [args, opts]; ['', '', fake_status] }) do
        S.show_diagnostic('diagnostic text')
      end
    end
    assert_equal ['/usr/bin/pbcopy'], captured[0]
    assert_equal 'diagnostic text', captured[1][:stdin_data]
    assert_empty answers
  end

  def test_http_diagnostic_status_and_transport_failures
    fake = Struct.new(:success?, :exitstatus)
    [[true, 0, '401', 'NET-HTTP-401'], [true, 0, '403', 'NET-HTTP-403'],
     [true, 0, '500', 'NET-HTTP-500'], [false, 28, '000', 'NET-CURL-28'],
     [false, 6, '000', 'NET-CURL-6'], [false, 60, '000', 'NET-CURL-60']].each do |ok, exitcode, out, code|
      Open3.stub(:capture3, [out, 'synthetic-key', fake.new(ok, exitcode)]) do
        result = S.verify_result('synthetic-key')
        refute result[:ok]
        assert_equal code, result[:code]
        refute_includes result[:reason], 'synthetic-key'
        assert_includes S.diagnostic_text('verify', result[:reason], :saved, code: code), '配置已保存'
      end
    end
    assert_equal 'NET-KEY-001', S.verify_result("bad\nkey")[:code]
  end

  def with_fake_run(answers, network, original: '', launch_ok: true, running_states: nil)
    Dir.mktmpdir('codex-flow-', File.dirname(__FILE__)) do |dir|
      old_home = ENV['CODEX_HOME']
      ENV['CODEX_HOME'] = dir
      File.write(File.join(dir, 'config.toml'), original) unless original.empty?
      prompts, diagnostics, launches = [], [], []
      capture = Open3.method(:capture3)
      fake = Struct.new(:success?, :exitstatus).new(launch_ok, launch_ok ? 0 : 1)
      Open3.stub(:capture3, lambda { |*args, **opts|
        if args[0] == '/usr/bin/open'
          launches << args
          ['', '', fake]
        else
          capture.call(*args, **opts)
        end
      }) do
        S.stub(:app_candidates, ['/Applications/Fake-Codex.app']) do
          S.stub(:running?, lambda { running_states ? running_states.shift : false }) do
            S.stub(:dialog, lambda { |text, *args, **opts| prompts << text; answers.shift }) do
              S.stub(:verify_result, network) do
                S.stub(:show_diagnostic, lambda { |text| diagnostics << text }) do
                  yield dir, prompts, diagnostics, launches, S.run
                end
              end
            end
          end
        end
      end
    ensure
      ENV['CODEX_HOME'] = old_home
    end
  end

  def test_success_flow_has_only_key_dialog_and_launches_automatically
    with_fake_run(['new-key'], { ok: true }) do |dir, prompts, diagnostics, launches, result|
      assert_equal true, result
      assert_equal ['请输入网关密钥'], prompts
      assert_empty diagnostics
      assert_equal 1, launches.length
      assert_equal 'new-key', S::Document.new(File.read(File.join(dir, 'config.toml'))).entries[%w[model_providers custom experimental_bearer_token]]
    end
  end

  def test_verification_failure_is_saved_diagnostic_and_does_not_launch
    with_fake_run(['new-key'], { ok: false, code: 'NET-HTTP-401', reason: 'HTTP 401' }) do |dir, prompts, diagnostics, launches, result|
      assert_nil result
      assert_equal ['请输入网关密钥'], prompts
      assert_equal 1, diagnostics.length
      assert_includes diagnostics[0], 'NET-HTTP-401'
      assert_includes diagnostics[0], '配置已保存'
      refute_includes diagnostics[0], 'new-key'
      assert_empty launches
      assert File.file?(File.join(dir, 'config.toml'))
    end
  end

  def test_cancel_empty_key_does_not_write_or_launch
    with_fake_run([''], { ok: true }) do |dir, prompts, diagnostics, launches, result|
      assert_nil result
      assert_empty diagnostics
      assert_empty launches
      refute File.exist?(File.join(dir, 'config.toml'))
    end
  end

  def test_diagnostic_reports_uncertain_save_and_redacts_known_key
    notice = S.diagnostic_text('save', IOError.new('failure synthetic-key'), :saving, token: 'synthetic-key')
    assert_includes notice, '保存未完整结束'
    refute_includes notice, 'synthetic-key'
    refute_includes notice, '配置文件未修改'
  end

  def test_full_existing_key_confirmation_flow
    original = "[model_providers.custom]\nbase_url = '#{S.gateway_url}'\nexperimental_bearer_token = 'old-key'\n"
    [[['使用现有密钥'], 'old-key'], [['输入新密钥', 'replacement'], 'replacement']].each do |answers, expected|
      with_fake_run(answers, { ok: true }, original: original) do |dir, prompts, diagnostics, launches, result|
        assert_equal true, result
        assert_equal '检测到已有网关密钥，是否使用？', prompts.first
        assert_equal(expected == 'old-key' ? 1 : 2, prompts.length)
        assert_empty diagnostics
        assert_equal 1, launches.length
        assert_equal expected, S::Document.new(File.read(File.join(dir, 'config.toml'))).entries[%w[model_providers custom experimental_bearer_token]]
      end
    end
  end

  def test_launch_failure_reports_saved_state
    with_fake_run(['new-key'], { ok: true }, launch_ok: false) do |dir, prompts, diagnostics, launches, result|
      assert_equal false, result
      assert_equal 1, diagnostics.length
      assert_includes diagnostics[0], 'CFG-LAUNCH-001'
      assert_includes diagnostics[0], '配置已保存'
      assert File.file?(File.join(dir, 'config.toml'))
    end
  end

  def test_second_running_check_cancel_does_not_save
    with_fake_run(['new-key', '取消'], { ok: true }, running_states: [false, true]) do |dir, prompts, diagnostics, launches, result|
      assert_nil result
      assert_equal 2, prompts.length
      assert_empty diagnostics
      assert_empty launches
      refute File.exist?(File.join(dir, 'config.toml'))
    end
  end

  def test_actual_osascript_cancel_status
    fake_status = Struct.new(:success?).new(false)
    Open3.stub(:capture3, ['', 'execution error: User canceled. (-128)', fake_status]) do
      assert_raises(S::Cancelled) { S.dialog('请输入网关密钥', ['取消', '确定'], input: true) }
    end
  end

  def test_network_diagnostic_redacts_escaped_key
    key = 'key"\\special'
    escaped = key.gsub(/[\\"]/) { |character| '\\' + character }
    fake_status = Struct.new(:success?, :exitstatus).new(false, 7)
    Open3.stub(:capture3, ['000', "curl failure #{escaped}", fake_status]) do
      result = S.verify_result(key)
      refute_includes result[:reason], escaped
      refute_includes result[:reason], key
      assert_includes result[:reason], '[已省略密钥]'
    end
  end

  def test_diagnostic_dialog_failure_keeps_diagnostic_in_terminal
    S.stub(:dialog, lambda { |*args| raise S::Unsafe, 'osascript unavailable' }) do
      _, err = capture_io { S.show_diagnostic('CFG-PARSE-001 retained diagnostic') }
      assert_includes err, 'CFG-PARSE-001 retained diagnostic'
      assert_includes err, '诊断弹窗失败'
    end
  end

  def test_clipboard_failure_keeps_diagnostic_and_reports_copy_failure
    prompts = []
    S.stub(:dialog, lambda { |text, *args| prompts << text; prompts.length == 1 ? '复制诊断信息' : '关闭' }) do
      Open3.stub(:capture3, ['', 'pbcopy unavailable', Struct.new(:success?).new(false)]) do
        _, err = capture_io { S.show_diagnostic('original diagnostic') }
        assert_includes err, 'original diagnostic'
        assert_includes prompts.last, 'pbcopy unavailable'
      end
    end
  end

  def test_http_header_goes_to_stdin_not_argv
    singleton = Open3.singleton_class
    singleton.alias_method :original_capture3_for_test, :capture3
    captured = nil
    fake = Object.new
    def fake.success?; true; end
    singleton.define_method(:capture3) { |*args, **opts| captured = [args, opts]; ['200', '', fake] }
    secret = 'key"\\special'
    assert S.verify(secret)
    refute_includes captured[0].join(' '), secret
    assert_includes captured[1][:stdin_data], 'key\\"\\\\special'
    refute_includes captured[0], '--location'
    refute S.verify("bad\nheader")
  ensure
    if singleton && singleton.method_defined?(:original_capture3_for_test)
      singleton.alias_method :capture3, :original_capture3_for_test
      singleton.remove_method :original_capture3_for_test
    end
  end
end
