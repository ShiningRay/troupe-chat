# TroupeChat 应用 UI：登录态与房间态两块面板切换（visible 驱动，保留树重建）。
#
# 帧循环职责：host 每帧调 pump()（网络 inbox → 模型）+ tick()（自动化脚本），
# 变化经 sync() 同步到组件；其余时间零重排（Kit retained 树按需失效）。

require "tessell/kit"
require "protocol"
require "./chat_model"
require "./ws_client"
require "./chat_components"

module ChatUI
  class ChatApp
    getter model : ChatModel
    getter log : ChatLog
    getter members : MembersPanel
    getter entry : Tessell::Kit::Input
    getter nick_input : Tessell::Kit::Input
    getter ws : WsClient

    property autotest : Bool = false
    property auto_send_text : String = "hello from tessell"

    @server_input : Tessell::Kit::Input
    @room_input : Tessell::Kit::Input
    @login_status : Tessell::Kit::Text
    @header_status : Tessell::Kit::Text
    @login_panel : VBox
    @chat_panel : VBox
    @body : VBox
    @body_state : Symbol = :login
    @send_btn : Tessell::Kit::Button
    @connect_btn : Tessell::Kit::Button
    @root : Tessell::Kit::Root?
    @clipboard : Tessell::Kit::Clipboard?
    @frames : Int32 = 0
    @structure_dirty : Bool = false
    @auto_connected = false
    @auto_sent = false
    @auto_acked = false
    @joined_frame : Int32 = -1

    # 面板摘挂后需要宿主补一次 root.layout（布局只在 layout 时发生）。
    def consume_structure_dirty : Bool
      d = @structure_dirty
      @structure_dirty = false
      d
    end

    def initialize(@server : String = "ws://127.0.0.1:7777", nick : String = "",
                   @room_prefill : String = "lobby")
      @model = ChatModel.new
      @ws = WsClient.new
      @body = VBox.new(Tessell::UI::UiKey.root.child(999_u64), 8.0_f32)

      k = key_gen
      @log = ChatLog.new(k.call)
      @members = MembersPanel.new(k.call)
      @entry = Tessell::Kit::Input.new(k.call, "", "输入消息，回车发送…", "", Tessell::Kit::ControlSize::Medium)
      @nick_input = Tessell::Kit::Input.new(k.call, nick, "昵称", "昵称", Tessell::Kit::ControlSize::Medium)
      @room_input = Tessell::Kit::Input.new(k.call, @room_prefill, "房间", "房间", Tessell::Kit::ControlSize::Medium)
      @server_input = Tessell::Kit::Input.new(k.call, @server, "ws://127.0.0.1:7777", "服务地址",
        Tessell::Kit::ControlSize::Medium)
      @login_status = Tessell::Kit::Text.new(k.call, "填写地址与昵称后连接", Tessell::Kit::TextTone::Muted,
        Tessell::Kit::ControlSize::Small)
      @header_status = Tessell::Kit::Text.new(k.call, "未连接", Tessell::Kit::TextTone::Muted,
        Tessell::Kit::ControlSize::Small)
      @send_btn = Tessell::Kit::Button.new(k.call, "发送", Tessell::Kit::Variant::Primary)
      @connect_btn = Tessell::Kit::Button.new(k.call, "连接", Tessell::Kit::Variant::Primary)
      @login_panel = VBox.new(k.call, 10.0_f32)
      @chat_panel = VBox.new(k.call, 8.0_f32)
      @root = nil
    end

    private def key_gen
      seq = 0_u64
      -> { Tessell::UI::UiKey.root.child(seq += 1_u64) }
    end

    def build_root(metrics : Tessell::Kit::TextMetrics,
                   clipboard : Tessell::Kit::Clipboard) : Tessell::Kit::Root
      @clipboard = clipboard
      [@entry, @nick_input, @room_input, @server_input].each do |input|
        input.clipboard = clipboard
      end

      # ---- 登录面板 ----
      @connect_btn.on_click = -> { connect_action }
      @nick_input.on_submit = ->(_t : String) { connect_action }
      @room_input.on_submit = ->(_t : String) { connect_action }
      @server_input.on_submit = ->(_t : String) { connect_action }

      login_row1 = HBox.new(Tessell::UI::UiKey.root.child(900_u64), 8.0_f32)
      login_row1.add(@nick_input, 1.0_f32)
      login_row1.add(@room_input, 1.0_f32)
      login_row2 = HBox.new(Tessell::UI::UiKey.root.child(901_u64), 8.0_f32)
      login_row2.add(@server_input, 1.0_f32)
      login_row2.add(@connect_btn)
      @login_panel.add(login_row1)
      @login_panel.add(login_row2)
      @login_panel.add(@login_status)

      # ---- 房间面板 ----
      @send_btn.on_click = -> { send_action }
      @entry.on_submit = ->(_t : String) { send_action }

      content_row = HBox.new(Tessell::UI::UiKey.root.child(910_u64), 8.0_f32)
      content_row.add(@log, 1.0_f32)
      content_row.add(@members)
      bottom_row = HBox.new(Tessell::UI::UiKey.root.child(911_u64), 8.0_f32)
      bottom_row.add(@entry, 1.0_f32)
      bottom_row.add(@send_btn)
      @chat_panel.add(content_row, 1.0_f32)
      @chat_panel.add(bottom_row)

      # ---- 头部 ----
      header = Tessell::Kit::Row.new(Tessell::UI::UiKey.root.child(920_u64), Tessell::Insets.new,
        8.0_f32, Tessell::Kit::Alignment::Center)
      header.add(Tessell::Kit::Text.new(Tessell::UI::UiKey.root.child(921_u64), "TroupeChat",
        Tessell::Kit::TextTone::Normal, Tessell::Kit::ControlSize::Large))
      header.add(Tessell::Kit::Text.new(Tessell::UI::UiKey.root.child(922_u64),
        "troupe.cr × tessell", Tessell::Kit::TextTone::Muted, Tessell::Kit::ControlSize::Small))
      header.add(@header_status)

      # 面板切换走"摘挂"而非 visible：Kit/VBox 布局对 invisible 子项不腾位。
      @body = VBox.new(Tessell::UI::UiKey.root.child(930_u64), 8.0_f32)
      @body.add(@login_panel, 1.0_f32)
      @body_state = :login
      @chat_panel.visible = false

      root_col = VBox.new(Tessell::UI::UiKey.root.child(940_u64), 8.0_f32, Tessell::Insets.all(12.0_f32))
      root_col.add(header)
      root_col.add(@body, 1.0_f32)

      root = Tessell::Kit::Root.new(root_col, Tessell::Kit::Theme.dark, metrics,
        Tessell::Rect.new(0.0_f32, 0.0_f32, 1000.0_f32, 680.0_f32))
      @root = root
      sync
      root
    end

    # ---- 动作 ----

    def connect_action : Nil
      return unless @model.state == :idle
      server = @server_input.text.strip
      nick = @nick_input.text.strip
      room = @room_input.text.strip
      if server.empty?
        server = "ws://127.0.0.1:7777"
        @server_input.set_text(server)
      end
      if nick.empty?
        @model.login_error = "昵称不能为空"
        @model.status = "昵称不能为空"
        sync
        return
      end
      room = "lobby" if room.empty?
      @model.mark_connecting
      @ws.connect(server, room, nick)
      sync
    end

    def send_action : Nil
      return unless @model.state == :joined
      text = @entry.text.strip
      return if text.empty?
      cid = Random::Secure.hex(8)
      @ws.send(Chat::Protocol.say(text, cid))
      @entry.set_text("")
    end

    # ---- 帧循环 ----

    def pump : Nil
      while msg = poll_message
        STDERR.puts "[dbg] ingest #{msg["type"]?} #{msg.to_json[0, 80]}" if ENV["CHAT_DEBUG"]?
        @model.ingest(msg)
        if @model.state == :joined && @joined_frame < 0
          @joined_frame = @frames
          puts "[chat] joined room=#{@model.room} you=#{@model.you} members=#{@model.members.size}"
        end
      end
      if @model.consume_dirty > 0
        sync
      end
    end

    def tick : Nil
      @frames += 1
      return unless @autotest
      if !@auto_connected && @frames >= 5 && @model.state == :idle
        @auto_connected = true
        puts "[autotest] connecting…"
        connect_action
      end
      if @model.state == :joined && !@auto_sent && @frames >= @joined_frame + 30
        @auto_sent = true
        puts "[autotest] sending: #{@auto_send_text}"
        @entry.set_text(@auto_send_text)
        send_action
      end
      if @auto_sent && !@auto_acked && @model.status.starts_with?("消息 #")
        @auto_acked = true
        puts "[autotest] acked: #{@model.status}"
      end
    end

    def autotest_done? : Bool
      @autotest && @auto_acked
    end

    private def poll_message : JSON::Any?
      msg = nil
      select
      when m = @ws.inbox.receive
        msg = m
      when timeout 1.millisecond
        msg = nil
      end
      msg
    rescue Channel::ClosedError
      nil
    end

    private def sync : Nil
      in_room = @model.state == :joined
      # 面板摘挂：布局槽位随之切换（invisible 不腾位，单靠 visible 会留空洞）。
      if in_room && @body_state != :room
        @body.remove(@login_panel)
        @body.add(@chat_panel, 1.0_f32)
        @body_state = :room
        @structure_dirty = true
      elsif !in_room && @body_state != :login
        @body.remove(@chat_panel)
        @body.add(@login_panel, 1.0_f32)
        @body_state = :login
        @structure_dirty = true
      end
      @login_panel.visible = !in_room
      @chat_panel.visible = in_room

      case @model.state
      when :idle
        @login_status.content = @model.login_error.empty? ? "填写地址与昵称后连接" : @model.login_error
        @header_status.content = "未连接"
      when :connecting
        @login_status.content = "连接中…"
        @header_status.content = "连接中…"
      else
        # 规避 tessell Kit Text#truncate 的 builder-repr bug（issue 待提）：
        # 长文本会渲染成 #<String::Builder:…>，header 只放短文案。
        @header_status.content = "#{@model.room} · #{@model.members.size} 人"
        rows = ChatLog.from_messages(@model.messages, @model.you)
        STDERR.puts "[dbg] sync msgs=#{@model.messages.size} rows=#{rows.size}" if ENV["CHAT_DEBUG"]?
        @log.set_rows(rows)
        @members.you = @model.you
        @members.set_members(@model.members)
      end
    end

    def login_focus_target : Tessell::Kit::Component
      @nick_input
    end

    def entry_focus_target : Tessell::Kit::Component
      @entry
    end
  end
end
