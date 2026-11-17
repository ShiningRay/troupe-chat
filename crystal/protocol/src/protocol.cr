# TroupeChat 共享协议。
#
# 客户端 ⇄ 服务端的全部消息都是 JSON 文本帧（详见 docs/protocol.md）。
# 本 shard 零运行时依赖，服务端与客户端各自以 path 依赖引入，保证两端编解码一致。

require "json"

module Chat
  module Protocol
    VERSION = "0.1.0"

    class ParseError < ::Exception; end

    # 一条聊天消息（历史/广播/welcome 复用同一形状）。
    # from == "" 表示系统消息（进入/离开提示由客户端本地生成时不经过服务端；
    # 服务端下发的 joined/left 事件由客户端转成系统行）。
    record ChatMessage, id : Int64, from : String, text : String, ts : Int64 do
      include JSON::Serializable

      def initialize(@id : Int64, @from : String, @text : String, @ts : Int64)
      end
    end

    # ---- 客户端 → 服务端 ----

    record JoinMsg, room : String, nick : String
    record SayMsg, text : String, cid : String

    # 解析客户端上行消息。join/say 返回对应 record，leave/ping 返回 Symbol。
    # 非法结构抛 ParseError。
    def self.parse_client(json : JSON::Any) : JoinMsg | SayMsg | Symbol
      type = json["type"]?.try(&.as_s?)
      raise ParseError.new("缺少 type 字段") unless type
      case type
      when "join"
        JoinMsg.new(require_string(json, "room"), require_string(json, "nick"))
      when "say"
        text = require_string(json, "text")
        cid = json["cid"]?.try(&.as_s?) || ""
        SayMsg.new(text, cid)
      when "leave"
        :leave
      when "ping"
        :ping
      else
        raise ParseError.new("未知消息类型：#{type}")
      end
    end

    def self.join(room : String, nick : String) : String
      JSON.build do |json|
        json.object do
          json.field "type", "join"
          json.field "room", room
          json.field "nick", nick
        end
      end
    end

    def self.say(text : String, cid : String) : String
      JSON.build do |json|
        json.object do
          json.field "type", "say"
          json.field "text", text
          json.field "cid", cid
        end
      end
    end

    def self.leave : String
      JSON.build do |json|
        json.object do
          json.field "type", "leave"
        end
      end
    end

    def self.ping : String
      JSON.build do |json|
        json.object do
          json.field "type", "ping"
        end
      end
    end

    # ---- 服务端 → 客户端 ----

    def self.welcome(room : String, you : String, members : Array(String),
                     history : Array(ChatMessage), last_id : Int64) : JSON::Any
      build_any do |json|
        json.field "type", "welcome"
        json.field "room", room
        json.field "you", you
        write_members(json, members)
        json.field "last_id", last_id
        write_history(json, history)
      end
    end

    def self.chat_msg(room : String, id : Int64, from : String, text : String, ts : Int64) : JSON::Any
      build_any do |json|
        json.field "type", "chat"
        json.field "room", room
        json.field "id", id
        json.field "from", from
        json.field "text", text
        json.field "ts", ts
      end
    end

    def self.ack(cid : String, id : Int64) : JSON::Any
      build_any do |json|
        json.field "type", "ack"
        json.field "cid", cid
        json.field "id", id
      end
    end

    def self.joined(room : String, nick : String, members : Array(String)) : JSON::Any
      presence("joined", room, nick, members)
    end

    def self.left(room : String, nick : String, members : Array(String)) : JSON::Any
      presence("left", room, nick, members)
    end

    def self.error(code : String, message : String) : JSON::Any
      build_any do |json|
        json.field "type", "error"
        json.field "code", code
        json.field "message", message
      end
    end

    def self.pong : JSON::Any
      build_any { |json| json.field "type", "pong" }
    end

    def self.disconnected(reason : String) : JSON::Any
      build_any do |json|
        json.field "type", "disconnected"
        json.field "reason", reason
      end
    end

    # ---- 内部工具 ----

    private def self.presence(kind : String, room : String, nick : String, members : Array(String)) : JSON::Any
      build_any do |json|
        json.field "type", kind
        json.field "room", room
        json.field "nick", nick
        write_members(json, members)
      end
    end

    private def self.write_members(json : JSON::Builder, members : Array(String)) : Nil
      json.field "members" do
        json.array do
          members.each { |m| json.string(m) }
        end
      end
    end

    private def self.write_history(json : JSON::Builder, history : Array(ChatMessage)) : Nil
      json.field "history" do
        json.array do
          history.each { |msg| msg.to_json(json) }
        end
      end
    end

    private def self.require_string(json : JSON::Any, key : String) : String
      value = json[key]?.try(&.as_s?)
      raise ParseError.new("缺少字段 #{key}") unless value && !value.empty?
      value
    end

    # 所有下行消息都是单层 JSON object；在这里统一包裹，调用方只写字段。
    private def self.build_any(&) : JSON::Any
      JSON.parse(JSON.build do |json|
        json.object do
          yield json
        end
      end)
    end
  end
end
