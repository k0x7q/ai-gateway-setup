#!/usr/bin/ruby
# frozen_string_literal: true
# Deliberately conservative TOML editor: unsupported constructs fail closed.
require 'strscan'
require 'uri'
require 'open3'
require 'digest'
require 'securerandom'
require 'fileutils'

module CodexSetup
  APP_ID = 'com.openai.codex'
  class Unsafe < StandardError
    attr_accessor :line
    def initialize(message = '配置语法不受支持或不完整')
      super(message)
    end
  end
  class Cancelled < StandardError; end
  module_function

  def gateway_origin(value = ENV['AI_GATEWAY_URL'])
    unless value.is_a?(String) && /\Ahttps:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?\/?\z/.match?(value)
      raise Unsafe, '请通过 AI_GATEWAY_URL 提供 HTTPS 网关域名地址，不可包含账号、路径、查询参数或片段。'
    end
    begin
      uri = URI.parse(value)
      raise URI::InvalidURIError unless uri.host && uri.port.between?(1, 65535)
      host = uri.host.downcase
      "https://#{host}#{uri.port == 443 ? '' : ':' + uri.port.to_s}"
    rescue URI::InvalidURIError
      raise Unsafe, '网关地址或端口无效。'
    end
  end

  def gateway_url; gateway_origin + '/v1'; end

  def read_string(s)
    raise Unsafe, '不支持多行字符串（三引号）' if s.peek(3) == '"""' || s.peek(3) == "'''"
    quote = s.getch
    raise Unsafe, '字符串缺少引号' unless quote == '"' || quote == "'"
    out = +''
    loop do
      c = s.getch
      raise Unsafe, '字符串未闭合、使用了多行字符串或含非法控制字符' if c.nil? || c == "\n" || c == "\r" || c.ord < 0x20
      return out if c == quote
      if c == '\\' && quote == '"'
        e = s.getch
        case e
        when '"', '\\' then out << e
        when 'b' then out << "\b"
        when 't' then out << "\t"
        when 'n' then out << "\n"
        when 'f' then out << "\f"
        when 'r' then out << "\r"
        when 'u', 'U'
          digits = s.scan(e == 'u' ? /[0-9A-Fa-f]{4}/ : /[0-9A-Fa-f]{8}/)
          raise Unsafe, 'Unicode 转义格式无效' unless digits
          cp = digits.to_i(16)
          raise Unsafe, 'Unicode 转义超出有效字符范围' if cp > 0x10ffff || (0xd800..0xdfff).cover?(cp)
          out << [cp].pack('U')
        else raise Unsafe, '字符串转义不受支持'
        end
      else
        out << c
      end
    end
  end

  def key(s)
    if s.peek(1) == '"' || s.peek(1) == "'"
      read_string(s)
    else
      s.scan(/[A-Za-z0-9_-]+/) || (raise Unsafe, '键名或表名格式不受支持')
    end
  end

  def whitespace(s); s.skip(/[ \t]*/); end
  def value(s)
    whitespace(s)
    if s.peek(1) == '"' || s.peek(1) == "'"
      read_string(s)
    elsif s.peek(1) == '['
      s.getch
      whitespace(s)
      unless s.peek(1) == ']'
        loop do
          value(s)
          whitespace(s)
          break if s.peek(1) == ']'
          raise Unsafe, '数组缺少逗号或使用了多行数组' unless s.getch == ','
          whitespace(s)
          break if s.peek(1) == ']'
        end
      end
      raise Unsafe, '数组或表未闭合，不支持多行数组' unless s.getch == ']'
      :array
    else
      raise Unsafe, '不支持内联表 { ... }' if s.peek(1) == '{'
      raw = s.scan(/[^ \t,#\]]+/)
      raise Unsafe, '设置项缺少值或数组不完整' unless raw
      # Restricted subset of valid TOML. Reject unrecognised values, dates and inline tables.
      scalar = /\A(?:true|false|[+-]?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?|[+-]?(?:inf|nan))\z/
      raise Unsafe, '值格式不受支持：可能是内联表、日期时间或无效数值' unless scalar.match?(raw)
      :scalar
    end
  end

  def toml_string(str)
    raise Unsafe, '待写入的字符串不是有效的 UTF-8 文本' unless str.is_a?(String) && str.valid_encoding?
    '"' + str.each_codepoint.map { |c|
      case c
      when 34 then '\\"'
      when 92 then '\\\\'
      when 8 then '\\b'
      when 9 then '\\t'
      when 10 then '\\n'
      when 12 then '\\f'
      when 13 then '\\r'
      when 0..31, 127 then format('\\u%04X', c)
      else [c].pack('U')
      end
    }.join + '"'
  end

  class Document
    attr_reader :entries
    def initialize(text)
      raise Unsafe, '配置文件超过 2 MB 大小限制' if text.bytesize > 2_000_000
      raise Unsafe, '配置文件不是有效的 UTF-8 编码' unless text.valid_encoding?
      raise Unsafe, '配置文件含有 UTF-8 BOM；当前 Mac 解析器不支持该格式' if text.start_with?("\uFEFF")
      if (bad = text.index(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/))
        error = Unsafe.new('配置文件含有非法控制字符')
        error.line = text[0...bad].count("\n") + 1
        raise error
      end
      @lines = text.lines
      @newline = text.include?("\r\n") ? "\r\n" : "\n"
      @entries, @locations, @headers = {}, {}, {}
      @nodes = { [] => :table }
      path = []
      @lines.each_with_index do |line, index|
        begin
          raise Unsafe, '不支持单独的 CR 换行符' if line.include?("\r") && !line.end_with?("\r\n")
          body = line.sub(/\r?\n\z/, '')
          s = StringScanner.new(body)
          CodexSetup.whitespace(s)
          next if s.eos? || s.peek(1) == '#'
          if s.peek(1) == '['
            s.getch
            raise Unsafe, '不支持数组表 [[...]]' if s.peek(1) == '['
            parts = []
            loop do
              CodexSetup.whitespace(s)
              parts << CodexSetup.key(s)
              CodexSetup.whitespace(s)
              break if s.peek(1) != '.'
              s.getch
            end
            raise Unsafe, '数组或表未闭合，不支持多行数组' unless s.getch == ']'
            CodexSetup.whitespace(s)
            raise Unsafe, '表头后有非注释内容' unless s.eos? || s.peek(1) == '#'
            parts.each_index do |i|
              prefix = parts[0..i]
              node = @nodes[prefix]
              raise Unsafe, '重复的表定义，或表与设置项冲突' if node == :value || (i == parts.length - 1 && node == :table)
              @nodes[prefix] ||= :implicit
            end
            @nodes[parts] = :table
            @headers[parts] = index
            path = parts
          else
            name = CodexSetup.key(s)
            CodexSetup.whitespace(s)
            # Dotted keys are not edited: their table-definition semantics are subtle.
            raise Unsafe, '设置项缺少等号，或使用了不支持的点分赋值键' unless s.getch == '='
            val = CodexSetup.value(s)
            CodexSetup.whitespace(s)
            comment = s.eos? ? '' : s.rest
            raise Unsafe, '值后有额外内容，或使用了不支持的多行字符串' unless comment.empty? || comment.start_with?('#')
            full = path + [name]
            raise Unsafe, '重复的设置项，或设置项与表冲突' if @nodes.key?(full)
            @nodes[full] = :value
            @entries[full] = val
            @locations[full] = [index, comment]
          end
        rescue Unsafe => error
          error.line ||= index + 1
          raise
        end
      end
      if @entries.key?(['model']) && !@entries[['model']].is_a?(String)
        error = Unsafe.new('model 必须是带引号的字符串')
        error.line = @locations[['model']][0] + 1
        raise error
      end
      provider = ['model_providers']
      target = provider + ['custom']
      conflict = [provider, target].find { |node| @nodes[node] == :value }
      if conflict
        error = Unsafe.new('model_providers 或 custom 被定义为值，无法写入网关分组')
        error.line = @locations[conflict][0] + 1
        raise error
      end
    end

    def render(secret)
      desired = {
        ['model_provider'] => 'custom',
        ['model_providers', 'custom', 'name'] => 'custom',
        ['model_providers', 'custom', 'wire_api'] => 'responses',
        ['model_providers', 'custom', 'requires_openai_auth'] => false,
        ['model_providers', 'custom', 'base_url'] => CodexSetup.gateway_url,
        ['model_providers', 'custom', 'experimental_bearer_token'] => secret
      }
      desired[['model']] = 'gpt-6.1-sol' unless @entries.key?(['model'])
      replacements, root_add, custom_add = {}, [], []
      desired.each do |path, val|
        rendered = val == false ? 'false' : CodexSetup.toml_string(val)
        line = "#{path.last} = #{rendered}"
        if @locations[path]
          index, comment = @locations[path]
          replacements[index] = line + (comment.empty? ? '' : " #{comment}") + @newline
        elsif path.length == 1
          root_add << line + @newline
        else
          custom_add << line + @newline
        end
      end
      result = root_add.join
      @lines.each_with_index do |line, i|
        result << (replacements[i] || line)
        if i == @headers[['model_providers', 'custom']] && !custom_add.empty?
          result << @newline unless result.end_with?("\n")
          result << custom_add.join
        end
      end
      if !custom_add.empty? && !@headers.key?(['model_providers', 'custom'])
        result << @newline unless result.empty? || result.end_with?("\n")
        result << "[model_providers.custom]#{@newline}" << custom_add.join
      end
      # Re-parse the result, including collision checks, before any file is changed.
      Document.new(result)
      result
    end
  end

  def reusable?(document)
    base = document.entries[['model_providers', 'custom', 'base_url']]
    token = document.entries[['model_providers', 'custom', 'experimental_bearer_token']]
    return false unless base.is_a?(String) && token.is_a?(String) && !token.empty?
    u = URI.parse(base)
    expected = URI.parse(gateway_origin)
    u.scheme == 'https' && u.host.to_s.downcase == expected.host && u.port == expected.port && !u.userinfo && !u.query && !u.fragment && ['', '/', '/v1', '/v1/'].include?(u.path)
  rescue URI::InvalidURIError
    false
  end

  def read_config(path)
    stat = File.lstat(path)
    raise Unsafe, '配置文件是符号链接或不是普通文件' unless stat.file? && !stat.symlink?
    raise Unsafe, '配置文件超过 2 MB 大小限制' if stat.size > 2_000_000
    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags) do |f|
      raise Unsafe, '读取期间配置文件被替换' unless f.stat.dev == stat.dev && f.stat.ino == stat.ino
      data = f.read(2_000_001).force_encoding(Encoding::UTF_8)
      raise Unsafe, '配置文件超过 2 MB 大小限制' if data.bytesize > 2_000_000
      [data, stat]
    end
  end

  def no_acl?(path)
    listing, err, status = Open3.capture3('/bin/ls', '-lde', path)
    raise Unsafe, "读取目录 ACL 失败（退出码 #{status.exitstatus}）：#{err.strip}" unless status.success?
    listing.lines.first.to_s[10] != '+' && !listing.lines.drop(1).any? { |line| line.match?(/\A\s+\d+:/) }
  end

  def safe_directory(dir)
    stat = File.lstat(dir)
    raise Unsafe, '配置目录不是普通目录或是符号链接' unless stat.directory? && !stat.symlink?
    raise Unsafe, '配置目录所有者不是当前用户' unless stat.uid == Process.euid
    raise Unsafe, '配置目录允许群组或其他用户写入' unless (stat.mode & 0022).zero?
    raise Unsafe, '配置目录有 ACL，不符合安全写入要求' unless no_acl?(dir)
    stat
  end

  def write_private(path, data)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) do |f|
      # Remove inherited macOS ACLs before any secret or backup data is written.
      _, err, status = Open3.capture3('/bin/chmod', '-N', path)
      raise Unsafe, "清除新文件 ACL 失败（退出码 #{status.exitstatus}）：#{err.strip}" unless status.success?
      listing, err, status = Open3.capture3('/bin/ls', '-lde', path)
      raise Unsafe, "检查新文件 ACL 失败（退出码 #{status.exitstatus}）：#{err.strip}" unless status.success?
      current = File.lstat(path)
      raise Unsafe, '新文件权限、类型或身份校验失败' unless current.file? && current.dev == f.stat.dev && current.ino == f.stat.ino && (current.mode & 0077).zero?
      raise Unsafe, '新文件仍存在 ACL' if listing.lines.drop(1).any? { |line| line.match?(/\A\s+\d+:/) } || listing.lines.first.to_s[10] == '+'
      f.write(data)
      f.flush
      f.fsync
    end
  end

  def save_config(dir, original, original_stat, rendered)
    directory_stat = safe_directory(dir)
    path = File.join(dir, 'config.toml')
    stamp = Time.now.strftime('%Y%m%d%H%M%S')
    backup = nil
    temp = File.join(dir, ".config.toml.#{SecureRandom.hex(12)}.tmp")
    if original_stat
      backup = File.join(dir, "config.toml.backup-#{stamp}-#{SecureRandom.hex(6)}")
      write_private(backup, original)
    end
    begin
      write_private(temp, rendered)
      now = safe_directory(dir)
      raise Unsafe, '保存期间配置目录被替换' unless now.dev == directory_stat.dev && now.ino == directory_stat.ino
      if original_stat
        current, current_stat = read_config(path)
        raise Unsafe, '保存期间原配置被修改或替换' unless current_stat.dev == original_stat.dev && current_stat.ino == original_stat.ino && Digest::SHA256.digest(current) == Digest::SHA256.digest(original)
        File.rename(temp, path)
      else
        # Hard-link creation fails atomically if another process created the file.
        File.link(temp, path)
        File.unlink(temp)
      end
    ensure
      File.unlink(temp) if File.exist?(temp)
    end
    backup
  end

  def dialog(text, buttons = ['关闭'], default = nil, input: false)
    escapes = { '\\' => '\\\\', '"' => '\\"', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t' }
    escaped = text.gsub(/[\\"\n\r\t]/) { |character| escapes.fetch(character) }
    choices = buttons.map { |b| '"' + b + '"' }.join(', ')
    default ||= buttons.last
    script = "display dialog \"#{escaped}\" buttons {#{choices}} default button \"#{default}\""
    script += ' cancel button "取消"' if buttons.include?('取消')
    script += ' default answer ""' if input
    script += "\n"
    script += input ? "text returned of result\n" : "button returned of result\n"
    out, err, status = Open3.capture3('/usr/bin/osascript', stdin_data: script)
    raise Cancelled if !status.success? && err.include?('(-128)')
    raise Unsafe, "弹窗调用失败（osascript）：#{err.strip}" unless status.success?
    out.sub(/\n\z/, '')
  end

  def app_candidates
    paths = ['/Applications/ChatGPT.app', '/Applications/Codex.app', File.expand_path('~/Applications/ChatGPT.app'), File.expand_path('~/Applications/Codex.app')]
    out, _, status = Open3.capture3('/usr/bin/mdfind', "kMDItemCFBundleIdentifier == '#{APP_ID}'")
    paths.concat(out.lines.map(&:strip)) if status.success?
    paths.uniq.select do |path|
      next false unless path.end_with?('.app') && File.directory?(path)
      plist = File.join(path, 'Contents', 'Info.plist')
      id, _, ok = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', plist)
      exe, _, ex_ok = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleExecutable', plist)
      ok.success? && ex_ok.success? && id.strip == APP_ID && ['Codex', 'ChatGPT'].include?(exe.strip) && File.executable?(File.join(path, 'Contents', 'MacOS', exe.strip))
    end
  end

  def running?
    script = "tell application \"System Events\" to return (count of (application processes whose bundle identifier is \"#{APP_ID}\")) > 0\n"
    out, err, status = Open3.capture3('/usr/bin/osascript', stdin_data: script)
    raise Unsafe, "无法检查 Codex 运行状态（System Events，退出码 #{status.exitstatus}）：#{err.strip}" unless status.success?
    raise Unsafe, 'System Events 返回的运行状态不是 true 或 false' unless %w[true false].include?(out.strip)
    out.strip == 'true'
  end

  def redact_token(text, token)
    return text.to_s unless token && !token.empty?
    escaped = token.gsub(/[\\"]/) { |character| '\\' + character }
    [token, escaped].uniq.sort_by { |value| -value.length }.inject(text.to_s) do |result, value|
      result.gsub(value, '[已省略密钥]')
    end
  end

  def verify_result(token)
    # The visible input does not put credentials into process arguments or diagnostics.
    unless token.ascii_only? && token.match?(/\A[\x20-\x7E]+\z/)
      return { ok: false, code: 'NET-KEY-001', reason: '密钥含非 ASCII 或控制字符，无法作为 HTTP Bearer 密钥发送' }
    end
    header = "Authorization: Bearer #{token}".gsub(/[\\"]/) { |c| '\\' + c }
    config = "header = \"#{header}\"\n"
    out, err, status = Open3.capture3('/usr/bin/curl', '--disable', '--silent', '--show-error', '--output', '/dev/null', '--write-out', '%{http_code}', '--connect-timeout', '5', '--max-time', '15', '--proto', '=https', gateway_url + '/models', '--config', '-', stdin_data: config)
    if status.success?
      return { ok: true } if out.match?(/\A2\d\d\z/)
      if out.match?(/\A\d{3}\z/)
        hint = { '401' => '密钥无效或未授权', '403' => '网关拒绝访问', '429' => '请求限流或额度不足' }[out]
        return { ok: false, code: "NET-HTTP-#{out}", reason: "HTTP #{out}#{hint ? '：' + hint : ''}" }
      end
      return { ok: false, code: 'NET-HTTP-INVALID', reason: 'curl 未返回有效的 HTTP 状态码' }
    end
    exit_code = status.exitstatus
    reason = { 5 => '代理域名解析失败', 6 => '网关域名解析失败', 7 => '连接网关失败', 28 => '请求超时', 35 => 'TLS 握手失败', 60 => 'TLS 证书校验失败' }[exit_code] || 'curl 请求失败'
    detail = redact_token(err.to_s.strip, token)
    { ok: false, code: "NET-CURL-#{exit_code || 'SIGNAL'}", reason: "#{reason}（curl 退出码：#{exit_code || '被信号终止'}）#{detail.empty? ? '' : "\n#{detail}"}" }
  rescue StandardError => error
    { ok: false, code: 'NET-REQUEST-001', reason: "#{error.class}: #{redact_token(error.message, token)}" }
  end

  def verify(token)
    verify_result(token)[:ok]
  end

  def diagnostic_text(stage, error, state, code: nil, token: nil)
    labels = {
      'app-detect' => '检测 Codex', 'app-check' => '检查 Codex 运行状态',
      'path' => '定位配置目录', 'read' => '读取已有配置', 'parse' => '解析已有配置',
      'key' => '选择或输入密钥', 'build' => '生成新配置', 'save' => '备份并保存配置',
      'verify' => '验证网关', 'launch' => '打开 Codex'
    }
    states = {
      :unchanged => '配置文件未修改',
      :saving => '保存未完整结束；可能已生成备份或写入配置，请检查配置和备份',
      :saved => '配置已保存'
    }
    reason = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    reason = redact_token(reason, token)
    line = error.respond_to?(:line) && error.line ? "\n位置：第 #{error.line} 行" : ''
    identifier = code || "CFG-#{stage.to_s.upcase}-001"
    "配置失败 [#{identifier}]\n阶段：#{labels[stage] || stage}\n原因：#{reason}#{line}\n配置状态：#{states[state] || state}"
  end

  def show_diagnostic(text)
    loop do
      break unless dialog(text, ['复制诊断信息', '关闭'], '关闭') == '复制诊断信息'
      _, err, status = Open3.capture3('/usr/bin/pbcopy', stdin_data: text)
      unless status.success?
        warn text
        dialog("复制失败：#{err.strip}", ['关闭'])
        break
      end
    end
  rescue StandardError => error
    warn text
    warn "诊断弹窗失败：#{error.class}"
  end

  def choose_token(document)
    if reusable?(document)
      answer = dialog('检测到已有网关密钥，是否使用？', ['取消', '输入新密钥', '使用现有密钥'], '使用现有密钥')
      raise Cancelled if answer == '取消'
      return document.entries[['model_providers', 'custom', 'experimental_bearer_token']] if answer == '使用现有密钥'
    end
    token = dialog('请输入网关密钥', ['取消', '确定'], '确定', input: true)
    raise Cancelled if token.strip.empty?
    token
  end

  def wait_closed
    while running?
      answer = dialog('Codex 正在运行，请保存工作并退出后重试。', ['取消', '重试'], '重试')
      raise Cancelled if answer == '取消'
    end
  end

  def run
    stage, state, token = 'app-detect', :unchanged, nil
    ENV['AI_GATEWAY_URL'] = gateway_origin
    app = nil
    opened_page = false
    loop do
      app = app_candidates.first
      break if app
      unless opened_page
        _, err, status = Open3.capture3('/usr/bin/open', 'https://openai.com/zh-Hans-CN/codex/')
        show_diagnostic(diagnostic_text(stage, "打开下载网站失败：#{err.strip}", state, code: 'APP-DOWNLOAD-001')) unless status.success?
        opened_page = true
      end
      answer = dialog('未检测到 Codex。请安装后重新检测，或继续配置。', ['取消', '已安装，继续', '重新检测'])
      raise Cancelled if answer == '取消'
      break if answer == '已安装，继续'
    end
    stage = 'app-check'
    wait_closed
    stage = 'path'
    home = ENV['CODEX_HOME']
    if home && !home.empty?
      dir = File.expand_path(home)
      raise Unsafe, '自定义 CODEX_HOME 不是已存在的目录' unless File.directory?(dir)
    else
      dir = File.join(Dir.home, '.codex')
      Dir.mkdir(dir, 0700) unless File.exist?(dir)
      raise Unsafe, '默认配置目录被同名文件占用' unless File.directory?(dir)
    end
    safe_directory(dir)
    path = File.join(dir, 'config.toml')
    stage = 'read'
    if File.exist?(path) || File.symlink?(path)
      original, original_stat = read_config(path)
    else
      original, original_stat = '', nil
    end
    stage = 'parse'
    document = Document.new(original)
    stage = 'key'
    token = choose_token(document)
    stage = 'build'
    rendered = document.render(token)
    stage = 'app-check'
    wait_closed
    stage, state = 'save', :saving
    save_config(dir, original, original_stat, rendered)
    state = :saved
    stage = 'verify'
    result = verify_result(token)
    unless result[:ok]
      show_diagnostic(diagnostic_text(stage, result[:reason], state, code: result[:code], token: token))
      return
    end
    stage = 'launch'
    raise Unsafe, '配置已完成，但未检测到 Codex 应用，无法自动打开' unless app
    _, err, status = Open3.capture3('/usr/bin/open', '-a', app)
    raise Unsafe, "启动 Codex 失败（退出码 #{status.exitstatus}）：#{err.strip}" unless status.success?
    # Success needs no confirmation dialog.
    true
  rescue Cancelled
    nil
  rescue StandardError => error
    show_diagnostic(diagnostic_text(stage, error, state, token: token))
    false
  end
end

CodexSetup.run if $PROGRAM_NAME == __FILE__
