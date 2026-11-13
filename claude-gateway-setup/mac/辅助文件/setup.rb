#!/usr/bin/ruby
# frozen_string_literal: true
require 'json'
require 'open3'
require 'shellwords'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'uri'

module ClaudeInstaller
  NODE_SITE = 'https://nodejs.org/zh-cn/download/'
  REGISTRY = 'https://registry.npmjs.org'
  MIN_NODE = 22
  MAX_BYTES = 2 * 1024 * 1024
  STAGES = %w[preflight key install-node install-claude configure path read parse build save].freeze
  CONFIG_STATES = %w[unchanged saving saved unknown].freeze
  DIAGNOSTIC_CODE = /\A(?:MAC_[A-Z0-9_]+|CFG[-_][A-Z0-9_-]+|SETUP-CANCELLED|E[A-Z0-9_]+)\z/
  class Failure < StandardError
    attr_reader :code, :line, :column
    def initialize(reason, code = 'MAC_OPERATION', line = nil, column = nil)
      super(reason)
      @code, @line, @column = code, line, column
    end
  end
  class Cancelled < StandardError; end
  class UniqueObject < Hash
    def []=(key, value)
      raise Failure.new('配置含重复 JSON 键；原文件未修改。', 'MAC_JSON_DUPLICATE') if key?(key)
      super
    end
  end
  module_function

  def gateway_origin(value = ENV['AI_GATEWAY_URL'])
    unless value.is_a?(String) && /\Ahttps:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?\/?\z/.match?(value)
      raise Failure, '请通过 AI_GATEWAY_URL 提供 HTTPS 网关域名地址，不可包含账号、路径、查询参数或片段。'
    end
    begin
      uri = URI.parse(value)
      raise URI::InvalidURIError unless uri.host && uri.port.between?(1, 65535)
      host = uri.host.downcase
      "https://#{host}#{uri.port == 443 ? '' : ':' + uri.port.to_s}"
    rescue URI::InvalidURIError
      raise Failure, '网关地址或端口无效。'
    end
  end

  def stage(name)
    @stage = name
  end

  def sanitize(text)
    clean = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
    variants = (@sensitive || []).flat_map do |value|
      value = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      [value, JSON.generate(value)[1...-1], value.gsub("'", "''"), URI.encode_www_form_component(value).gsub('+', '%20')]
    end
    variants.uniq.sort_by { |value| -value.length }.each do |value|
      clean = clean.gsub(value, '[已脱敏]') unless value.empty?
    end
    clean = clean.gsub(/(?:sk-|Bearer\s+)[A-Za-z0-9_.\-]+/i, '[已脱敏]')
    clean = clean.gsub(/(AUTH_TOKEN|API_KEY|token|key)(["'\s:=]+)[^\s,;]+/i, '\\1\\2[已脱敏]')
    # Never render JSON/configuration bodies from parser or child exceptions.
    clean = clean.gsub(/\{(?=\s*").*\}/m, '[JSON 内容已省略]')
    clean = clean.gsub(/\[(?=\s*(?:"|\{|\[|true\b|false\b|null\b|\d|-)).*\]/m, '[JSON 内容已省略]')
    clean.gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, '?')[0, 1500]
  end

  def remember_strings(value, credential = false)
    case value
    when Hash
      value.each { |key, entry| remember_strings(entry, credential || key.to_s.match?(/token|key|password|secret|credential|auth/i)) }
    when Array then value.each { |entry| remember_strings(entry, credential) }
    when String then (@sensitive ||= []) << value if credential && !value.empty?
    end
  end

  def capture_tool(*args)
    out, err, status = Open3.capture3(*args)
    [out, status, err]
  rescue StandardError => error
    raise Failure.new("系统工具无法执行（#{error.class}）：#{sanitize(error.message)}", 'MAC_TOOL_START')
  end

  def tool_failure(reason, status, stderr = '')
    detail = status.exitstatus ? "退出码 #{status.exitstatus}" : "信号 #{status.termsig}"
    diagnostic = sanitize(stderr).strip
    diagnostic = diagnostic.empty? ? '工具未提供 stderr' : "stderr：#{diagnostic}"
    raise Failure.new("#{reason}（#{detail}；#{diagnostic}）。", 'MAC_TOOL_EXIT')
  end

  def native(script)
    # Scripts (including a retry default value) travel over a private pipe, never argv/env/tempfiles.
    output, err, status = Open3.capture3('/usr/bin/osascript', '-', stdin_data: "with timeout of 86400 seconds\n#{script}\nend timeout")
    raise Cancelled if !status.success? && err.to_s.match?(/\(-128\)/)
    tool_failure('系统对话框未完成', status, err) unless status.success?
    output.sub(/\r?\n\z/, '')
  rescue Cancelled, Failure
    raise
  rescue StandardError => error
    raise Failure.new("系统对话框无法启动（#{error.class}）：#{sanitize(error.message)}", 'MAC_DIALOG_START')
  end

  def choose_key(settings)
    previous = settings.fetch('env', {})
    if previous['ANTHROPIC_BASE_URL'] == gateway_origin && previous['ANTHROPIC_AUTH_TOKEN'].is_a?(String) && !previous['ANTHROPIC_AUTH_TOKEN'].strip.empty?
      answer = native('button returned of (display dialog "检测到已有网关密钥，是否使用？" buttons {"取消", "输入新密钥", "使用现有密钥"} default button "使用现有密钥" cancel button "取消" with title "Claude Code 网关配置")')
      raise Cancelled if answer == '取消'
      return previous['ANTHROPIC_AUTH_TOKEN'] if answer == '使用现有密钥'
      raise Failure.new('密钥选择返回未知按钮。', 'MAC_KEY_CHOICE') unless answer == '输入新密钥'
    end
    current = ''
    loop do
      current = native("text returned of (display dialog \"请输入网关密钥\" default answer #{JSON.generate(current)} buttons {\"取消\", \"确定\"} default button \"确定\" cancel button \"取消\" with title \"Claude Code 网关配置\")")
      (@sensitive ||= []) << current unless current.empty?
      trimmed = current.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
      return trimmed if valid_key?(trimmed)
      native('display dialog "密钥不能为空、含空格或控制字符，且不能超过 8192 字符。请重试。" buttons {"继续"} default button "继续" with title "Claude Code 网关配置"')
      # JSON and AppleScript have different escapes for some controls; never embed those in a retry script.
      current = '' if current.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
    end
  end

  def valid_key?(token)
    token.is_a?(String) && !token.strip.empty? && token.length <= 8192 && !token.match?(/[[:space:]\x00-\x20\x7f]/)
  end

  def no_links(target)
    current = '/'
    target.split('/').reject(&:empty?).each do |part|
      current = File.join(current, part)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT
        next
      end
      raise Failure.new('配置路径存在符号链接；原文件未修改。', 'MAC_CONFIG_LINK') if stat.symlink?
      raise Failure.new('配置上级路径不是目录。', 'MAC_CONFIG_PATH') if current != target && !stat.directory?
    end
  end

  def safe_numbers(value)
    case value
    when Hash then value.each_value { |entry| safe_numbers(entry) }
    when Array then value.each { |entry| safe_numbers(entry) }
    when Integer
      raise Failure.new('配置含超出安全精度的数值；原文件未修改。', 'MAC_JSON_NUMBER') if value.abs > 9007199254740991
    when Float
      unless value.finite? && (value != value.to_i || value.abs <= 9007199254740991)
        raise Failure.new('配置含超出安全精度的数值；原文件未修改。', 'MAC_JSON_NUMBER')
      end
    end
  end

  def preflight(shared)
    raise Failure.new('辅助文件缺失或不是普通文件，请完整解压后重试。', 'MAC_HELPER_MISSING') unless File.file?(shared) && !File.symlink?(shared)
    # configure.cjs currently loads these modules at startup, even in prepared mode.
    ['dialogs.cjs'].each do |name|
      file = File.join(File.dirname(shared), name)
      raise Failure.new("辅助文件缺失：#{name}；请完整解压后重试。", 'MAC_HELPER_MISSING') unless File.file?(file) && !File.symlink?(file)
    end
    dir = ENV['CLAUDE_CONFIG_DIR'].to_s
    dir = File.join(Dir.home, '.claude') if dir.empty?
    raise Failure.new('CLAUDE_CONFIG_DIR 必须是本地绝对目录。', 'MAC_CONFIG_PATH') unless dir.start_with?('/') && !dir.start_with?('//')
    target = File.join(File.expand_path(dir), 'settings.json')
    no_links(target)
    begin
      stat = File.lstat(target)
    rescue Errno::ENOENT
      return { target: target, digest: nil, settings: {} }
    end
    unless stat.file? && stat.nlink == 1 && stat.size <= MAX_BYTES
      raise Failure.new('配置不是普通文件、存在硬链接或超过 2MB；原文件未修改。', 'MAC_CONFIG_FILE')
    end
    bytes = nil
    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    # The descriptor snapshot and prepared digest are rechecked by shared before saving.
    File.open(target, flags) do |file|
      opened = file.stat
      raise Failure.new('配置在读取时发生变化，请重试。', 'MAC_CONFIG_CHANGED') unless opened.ino == stat.ino && opened.dev == stat.dev
      bytes = file.read(MAX_BYTES + 1)
    end
    raise Failure.new('配置超过 2MB；原文件未修改。', 'MAC_CONFIG_FILE') if bytes.bytesize > MAX_BYTES
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise Failure.new('配置不是有效 UTF-8；原文件未修改。', 'MAC_JSON_ENCODING') unless text.valid_encoding?
    begin
      settings = JSON.parse(text.sub(/\A\uFEFF/, ''), object_class: UniqueObject, max_nesting: 100)
    rescue JSON::ParserError
      # Ruby 2.6 does not provide a reliable offset. Do not expose the parser's source excerpt.
      raise Failure.new('配置不是有效 JSON；请修复后重试，原文件未修改。', 'MAC_JSON_PARSE')
    end
    raise Failure.new('配置根节点和 env 必须是 JSON 对象。', 'MAC_JSON_SHAPE') unless settings.is_a?(Hash) && (!settings.key?('env') || settings['env'].is_a?(Hash))
    safe_numbers(settings)
    remember_strings(settings)
    { target: target, digest: Digest::SHA256.hexdigest(bytes), settings: settings }
  end

  def configure_prepared(node, shared, prepared, token)
    payload = { token: token, target: prepared[:target], expectedDigest: prepared[:digest] }
    @state[:configuration] = 'unknown'
    output, err, status = Open3.capture3(node, shared, '--prepared-stdin', stdin_data: JSON.generate(payload))
    begin
      result = JSON.parse(output, object_class: UniqueObject)
    rescue JSON::ParserError, Failure
      detail = status.exitstatus ? "退出码 #{status.exitstatus}" : "信号 #{status.termsig}"
      raise Failure.new("配置程序未返回有效单份 JSON（#{detail}；stdout 已省略；stderr：#{sanitize(err)}）。", 'MAC_CONFIG_PROTOCOL')
    end
    unless result.is_a?(Hash)
      raise Failure.new('配置程序返回格式异常。', 'MAC_CONFIG_PROTOCOL')
    end
    if result['ok'] == false && result['diagnostic'].is_a?(Hash)
      diagnostic = result['diagnostic']
      @state[:configuration] = diagnostic['state'] if CONFIG_STATES.include?(diagnostic['state'])
      @stage = diagnostic['stage'] if STAGES.include?(diagnostic['stage'])
      code = diagnostic['code']
      code = 'MAC_CONFIG_CHILD' unless code.is_a?(String) && code.length <= 80 && code.match?(DIAGNOSTIC_CODE)
      line = diagnostic['line']
      column = diagnostic['column']
      line = nil unless line.is_a?(Integer) && line > 0 && line <= MAX_BYTES + 1
      column = nil unless column.is_a?(Integer) && column > 0 && column <= MAX_BYTES + 1
      reason = diagnostic['reason'].is_a?(String) ? sanitize(diagnostic['reason']) : '配置程序未提供有效错误原因'
      detail = status.exitstatus ? "退出码 #{status.exitstatus}" : "信号 #{status.termsig}"
      raise Failure.new("#{reason}（配置程序#{detail}；stderr：#{sanitize(err)}）", code, line, column)
    end
    @state[:configuration] = 'saved' if result['ok'] == true && result['state'] == 'saved' && result['target'] == prepared[:target]
    tool_failure('配置程序异常退出', status, err) unless status.success?
    unless @state[:configuration] == 'saved' && result['verified'] == false && result['warnings'].is_a?(Array)
      raise Failure.new('配置程序返回不完整的保存状态。', 'MAC_CONFIG_PROTOCOL')
    end
    result
  rescue Failure
    raise
  rescue StandardError => error
    raise Failure.new("配置子进程异常（#{error.class}）：#{sanitize(error.message)}", 'MAC_CONFIG_CHILD')
  end

  def report_failure(error)
    code = error.is_a?(Failure) ? error.code : 'MAC_UNEXPECTED'
    reason = error.is_a?(Failure) ? error.message : "#{error.class}：#{error.message}"
    location = ''
    if error.is_a?(Failure) && error.line.is_a?(Integer) && error.line > 0
      location = "\nJSON 行：#{error.line}"
      location += "，列：#{error.column}" if error.column.is_a?(Integer) && error.column > 0
    end
    code = 'MAC_UNEXPECTED' unless code.is_a?(String) && code.length <= 80 && code.match?(DIAGNOSTIC_CODE)
    safe_stage = STAGES.include?(@stage) ? @stage : 'configure'
    config_state = CONFIG_STATES.include?(@state[:configuration]) ? @state[:configuration] : 'unknown'
    # Whitelisted control metadata must not be mangled by literal one-character key redaction.
    text = "错误编号：#{code}\n阶段：#{safe_stage}\n原因：#{sanitize(reason)}#{location}\n软件安装：Node=#{@state[:node]}；Claude Code=#{@state[:claude]}\n配置保存：#{config_state}\nPATH：#{@state[:path]}"
    warn text
    begin
      script = "set diagnosticText to #{JSON.generate(text)}\nset chosen to button returned of (display dialog diagnosticText buttons {\"关闭\", \"复制诊断信息\"} default button \"关闭\" with title \"Claude Code 配置未完成\")\nif chosen is \"复制诊断信息\" then set the clipboard to diagnosticText"
      native(script)
    rescue StandardError
      warn '系统诊断窗口未能显示；请复制上面的诊断信息。'
    end
    1
  end

  def download(url, target)
    raise Failure, '下载地址不是 HTTPS。' unless url.start_with?('https://')
    _, status, err = capture_tool('/usr/bin/curl', '--fail', '--silent', '--show-error', '--location',
                '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '15',
                '--max-time', '600', '--retry', '1', '--output', target, url)
    tool_failure("无法下载官方文件。可手动访问 #{NODE_SITE} 安装 Node.js LTS 后重试", status, err) unless status.success?
  end

  def latest_lts(rows)
    valid = rows.select { |r| r.is_a?(Hash) && r['lts'].is_a?(String) &&
      r['version'].to_s.match?(/\Av\d+\.\d+\.\d+\z/) &&
      r['files'].is_a?(Array) && r['files'].include?('osx-x64-pkg') }
    row = valid.max_by { |r| r['version'][1..-1].split('.').map(&:to_i) }
    raise Failure, '官网没有提供可用的 macOS LTS 安装包，请手动安装。' unless row
    row['version']
  end

  def verify_checksum(text, filename, actual)
    lines = text.lines.select { |line| line.match?(/\A[0-9a-fA-F]{64}\s+\*?#{Regexp.escape(filename)}\s*\z/) }
    raise Failure, '官网校验清单没有唯一的安装包记录，请手动安装。' unless lines.length == 1
    expected = lines.first.split.first.downcase
    raise Failure, '安装包 SHA-256 校验失败，已停止安装。请联系技术支持。' unless expected == actual.downcase
  end

  def executable(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
      file = File.join(dir, name)
      return file if File.file?(file) && File.executable?(file)
    end
    nil
  end

  def node_ready?
    original_path = ENV.fetch('PATH', '')
    original_path.split(File::PATH_SEPARATOR).uniq.each do |dir|
      node = File.join(dir, 'node'); npm = File.join(dir, 'npm')
      next unless File.file?(node) && File.executable?(node) && File.file?(npm) && File.executable?(npm)
      candidate_path = dir + File::PATH_SEPARATOR + original_path
      version, _, status = Open3.capture3(node, '--version')
      next unless status.success? && version.strip.match?(/\Av\d+\.\d+\.\d+\z/) && version[1..-1].to_i >= MIN_NODE
      _, _, npm_status = Open3.capture3({ 'PATH' => candidate_path }, npm, '--version')
      next unless npm_status.success?
      ENV['PATH'] = candidate_path
      return true
    end
    false
  end

  def install_node
    Dir.mktmpdir('claude-node-', File.realpath(Dir.tmpdir)) do |temp|
      # Ruby's block-form mktmpdir cleans only its own newly created, known absolute path.
      raise Failure, '临时目录无法安全使用。' unless File.realpath(temp) == File.expand_path(temp)
      index = File.join(temp, 'index.json')
      download('https://nodejs.org/dist/index.json', index)
      begin
        version = latest_lts(JSON.parse(File.read(index)))
      rescue JSON::ParserError, NoMethodError
        raise Failure, '官网版本列表无法解析，请手动安装 Node.js LTS 后重试。'
      end
      filename = "node-#{version}.pkg"
      package = File.join(temp, filename)
      puts "正在下载 Node.js 最新 LTS #{version}（官方通用 macOS 安装包）……"
      download("https://nodejs.org/dist/#{version}/#{filename}", package)
      checksums = File.join(temp, 'SHASUMS256.txt')
      download("https://nodejs.org/dist/#{version}/SHASUMS256.txt", checksums)
      verify_checksum(File.read(checksums), filename, Digest::SHA256.file(package).hexdigest)
      signature, status, err = capture_tool('/usr/sbin/pkgutil', '--check-signature', package)
      tool_failure('安装包签名检查失败', status, err) unless status.success?
      unless signature.match?(/Developer ID Installer: (?:Node\.js Foundation|OpenJS Foundation)/)
        raise Failure, '安装包签名无法验证为 Node.js/OpenJS 官方发布者，已停止。请手动从官网安装。'
      end
      puts '下载和校验通过。系统将要求管理员授权，只授权 Node.js 安装器；不会以管理员身份运行 npm 或配置程序。'
      command = ['/usr/sbin/installer', '-pkg', package, '-target', '/'].shelljoin
      script = "do shell script #{JSON.generate(command)} with administrator privileges"
      begin
        native(script)
      rescue Cancelled
        @state[:node] = 'installation-unknown' if @state
        raise
      end
      @state[:node] = 'installed-unverified' if @state
    end
    ENV['PATH'] = '/usr/local/bin:' + ENV.fetch('PATH', '')
    raise Failure, '已安装但 Node.js/npm 检测未通过，请重新打开脚本，或联系技术支持。' unless node_ready?
  end

  def ensure_user_bin
    bin = File.join(Dir.home, '.local', 'bin')
    no_links(bin)
    FileUtils.mkdir_p(bin, mode: 0700)
    raise Failure, '用户命令目录存在链接或不是目录，请联系技术支持。' unless File.directory?(bin) && !File.symlink?(bin)
    ENV['PATH'] = bin + File::PATH_SEPARATOR + ENV.fetch('PATH', '')
    # Create a dedicated tiny launcher, never rewrite shell startup files or global npm config.
    bin
  end

  def persist_user_bin(claude)
    marker = '# >>> Claude company gateway PATH >>>'
    node_bin = Shellwords.escape(File.dirname(executable('node')))
    claude_bin = Shellwords.escape(File.dirname(claude))
    block = "\n#{marker}\nexport PATH=#{claude_bin}:#{node_bin}:\"$HOME/.local/bin:$PATH\"\n# <<< Claude company gateway PATH <<<\n"
    # macOS defaults to zsh; bash login terminals are also supported.
    bash_profile = ['.bash_profile', '.bash_login', '.profile'].find { |name| File.exist?(File.join(Dir.home, name)) || File.symlink?(File.join(Dir.home, name)) } || '.bash_profile'
    zsh_dir = ENV['ZDOTDIR'].to_s.empty? ? Dir.home : File.expand_path(ENV['ZDOTDIR'])
    changed = 0
    [File.join(zsh_dir, '.zshrc'), File.join(Dir.home, bash_profile)].uniq.each do |file|
      if @state
        @state[:path] = changed.zero? ? 'unchanged' : 'partial'
      end
      no_links(file)
      raise Failure, '终端配置文件是链接，未修改。请联系技术支持设置命令路径。' if File.symlink?(file)
      existed = File.exist?(file)
      original_stat = existed ? File.lstat(file) : nil
      if original_stat && (!original_stat.file? || original_stat.nlink != 1)
        raise Failure.new('终端配置不是普通文件或存在硬链接，未修改。', 'MAC_PATH_FILE')
      end
      original = existed ? File.binread(file) : ''
      next if original.include?(block)
      if original.include?(marker)
        managed = /\n?# >>> Claude company gateway PATH >>>\n.*?# <<< Claude company gateway PATH <<<\n?/m
        raise Failure, '已有 PATH 标记块不完整，请联系技术支持；终端配置未修改。' unless original.match?(managed)
        updated = original.sub(managed, block)
      else
        updated = original + block
      end
      if File.exist?(file)
        backup = file + '.claude-gateway-backup-' + Time.now.strftime('%Y%m%d%H%M%S') + '-' + Process.pid.to_s
        File.open(backup, File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
          _, status, err = capture_tool('/bin/chmod', '-N', backup)
          tool_failure('无法保护终端配置备份，未修改命令路径', status, err) unless status.success?
          f.write(original)
        end
      end
      temp = file + '.claude-gateway-tmp-' + Process.pid.to_s
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
        _, status, err = capture_tool('/bin/chmod', '-N', temp)
        tool_failure('无法保护终端配置临时文件', status, err) unless status.success?
        f.write(updated); f.flush; f.fsync
      end
      no_links(file)
      changed_file = File.symlink?(file) || File.exist?(file) != existed
      if existed && !changed_file
        latest_stat = File.lstat(file)
        changed_file = latest_stat.ino != original_stat.ino || latest_stat.dev != original_stat.dev || latest_stat.nlink != 1 || File.binread(file) != original
      end
      raise Failure, '终端配置发生变化，请重新运行。' if changed_file
      File.rename(temp, file)
      changed += 1
      @state[:path] = 'partial' if @state
    end
    @state[:path] = 'saved' if @state
  end

  def install_claude(bin)
    existing = executable('claude')
    if existing
      _, _, status = Open3.capture3(existing, '--version')
      if status.success?
        puts '已检测到可运行的 Claude Code，保留现有版本。'
        return existing
      end
    end
    prefix = File.join(Dir.home, '.local', 'share', 'claude-gateway', 'npm')
    puts '[安装 Claude Code] 从 npm 官方仓库安装，安装目录属于当前用户……'
    no_links(prefix)
    _, status, err = capture_tool(executable('npm'), 'install', '-g', '@anthropic-ai/claude-code@latest',
      '--prefix', prefix, '--registry=' + REGISTRY, '--engine-strict',
      '--fetch-retries=1', '--fetch-timeout=60000')
    tool_failure('Claude Code npm 用户安装失败；不要使用 sudo npm', status, err) unless status.success?
    @state[:claude] = 'installed-unverified' if @state
    target = File.join(prefix, 'bin', 'claude')
    raise Failure, 'npm 已退出但没有生成 claude 命令，请联系技术支持。' unless File.executable?(target)
    launcher = File.join(bin, 'claude')
    # Refuse to replace any user's unrelated command, including broken links.
    body = "#!/bin/bash\n# Claude company gateway managed launcher\nexport PATH=#{Shellwords.escape(File.dirname(executable('node')))}:\"$PATH\"\nexec #{Shellwords.escape(target)} \"$@\"\n"
    if File.exist?(launcher) || File.symlink?(launcher)
      raise Failure, '用户 claude 启动器已存在但不属于本工具，未覆盖。请联系技术支持。' unless File.file?(launcher) && !File.symlink?(launcher) && File.read(launcher).include?("# Claude company gateway managed launcher\n")
      if File.read(launcher) != body
        temp = launcher + '.claude-gateway-tmp-' + Process.pid.to_s
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0700) { |f| f.write(body) }
        File.rename(temp, launcher)
      end
    else
      File.open(launcher, File::WRONLY | File::CREAT | File::EXCL, 0700) { |f| f.write(body) }
    end
    launcher
  end

  def supported_platform?
    RUBY_PLATFORM.include?('darwin')
  end

  def main
    @sensitive = ENV.select { |name, _| name.match?(/(?:KEY|TOKEN|PASSWORD|SECRET|AUTHORIZATION)/i) }.values.reject(&:empty?)
    @state = { node: 'not-checked', claude: 'not-checked', configuration: 'unchanged', path: 'unchanged' }
    stage('preflight')
    ENV['AI_GATEWAY_URL'] = gateway_origin
    raise Failure.new('仅支持 macOS，请使用对应系统的安装包。', 'MAC_PLATFORM') unless supported_platform?
    raise Failure.new('请不要用 sudo 运行本脚本，请以日常使用电脑的账号双击运行。', 'MAC_ROOT') if Process.euid.zero?
    puts '正在检查辅助文件和配置……'
    shared = File.expand_path('configure.cjs', __dir__)
    prepared = preflight(shared)
    stage('key')
    token = choose_key(prepared[:settings])
    @sensitive << token
    raise Failure.new('现有密钥格式无效，请选择输入新密钥后重试。', 'MAC_KEY_INVALID') unless valid_key?(token)
    stage('install-node')
    ready = node_ready?
    @state[:node] = ready ? 'existing' : 'not-installed'
    stage('install-claude')
    claude = executable('claude')
    if claude
      _, status, err = capture_tool(claude, '--version')
      claude = nil unless status.success?
    end
    @state[:claude] = claude ? 'existing' : 'not-installed'
    unless ready && claude
      stage(ready ? 'install-claude' : 'install-node')
      needed = []
      needed << 'Node.js LTS（官方 pkg，系统管理员授权）' unless ready
      needed << 'Claude Code（npm 官方仓库，当前用户安装）' unless claude
      choice = native("button returned of (display dialog #{JSON.generate('需要安装：' + needed.join('；') + '。是否继续？')} buttons {\"取消\", \"安装\"} default button \"安装\" cancel button \"取消\" with title \"Claude Code 网关配置\")")
      raise Cancelled if choice == '取消'
      raise Failure.new('安装确认返回未知按钮。', 'MAC_INSTALL_CHOICE') unless choice == '安装'
    end
    unless ready
      stage('install-node')
      @state[:node] = 'installation-started'
      install_node
      @state[:node] = 'installed'
    end
    unless claude
      stage('install-claude')
      @state[:claude] = 'installation-started'
      bin = ensure_user_bin
      claude = install_claude(bin)
      _, status, err = capture_tool(claude, '--version')
      tool_failure('Claude Code 已安装但版本检测失败', status, err) unless status.success?
      @state[:claude] = 'installed'
    end
    stage('configure')
    puts '正在保存配置……'
    saved = configure_prepared(executable('node'), shared, prepared, token)
    # Saving is not credential/model verification: this installer never sends a model request.
    (saved['warnings'] || []).each { |warning| puts "提示：#{sanitize(warning)}" if warning.is_a?(String) }
    token = nil
    stage('path')
    persist_user_bin(claude)
    puts '配置已保存，未验证网关密钥或模型。'
    puts '配置完成。请在项目目录打开新终端，运行 claude。'
    0
  rescue Cancelled
    puts '已取消。'
    0
  rescue StandardError => error
    report_failure(error)
  ensure
    @sensitive = []
  end
end

if $PROGRAM_NAME == __FILE__
  exit ClaudeInstaller.main
end
