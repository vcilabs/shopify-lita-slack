module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class MessageHandler
        def initialize(robot, robot_id, data)
          @robot = robot
          @robot_id = robot_id
          @data = data
          @type = data["type"]
        end

        def handle
          case type
          when "hello"
            handle_hello
          when "message"
            handle_message
          when "reaction_added", "reaction_removed"
            handle_reaction
          when "user_change", "team_join"
            handle_user_change
          when "bot_added", "bot_changed"
            handle_bot_change
          when "channel_created", "channel_rename", "group_rename"
            handle_channel_change
          when "error"
            handle_error
          else
            handle_unknown
          end
        end

        private

        attr_reader :data
        attr_reader :robot
        attr_reader :robot_id
        attr_reader :type

        def body
          normalized_text = nil
          if data["text"]
            normalized_text = data["text"].sub(/^\s*<@#{robot_id}>/, "@#{robot.mention_name}")
          end

          normalized_text = remove_formatting(normalized_text) unless normalized_text.nil?

          lines = Array(data["attachments"]).inject([normalized_text]){
            |total, att| total.concat parse_attachment(att)
          }
          lines.compact.join("\n")
        end

        def parse_attachment(attachment)
          lines = []
          lines << attachment["pretext"]
          lines << attachment["title"]
          lines << attachment["text"] || attachment["fallback"]
          Array(attachment["fields"]).map do |field|
            lines << field["title"]
            lines << field["value"]
          end
          lines.compact.map(&:strip).reject(&:empty?)
        end

        def remove_formatting(message)
          # https://api.slack.com/docs/formatting
          message = message.gsub(/
              <                    # opening angle bracket
              (?<type>[@#!])?      # link type
              (?<link>[^>|]+)      # link
              (?:\|                # start of |label (optional)
                  (?<label>[^>]+)  # label
              )?                   # end of label
              >                    # closing angle bracket
              /ix) do
            link  = Regexp.last_match[:link]
            label = Regexp.last_match[:label]

            case Regexp.last_match[:type]
              when '@'
                if label
                  label
                else
                  user = User.find_by_id(link)
                  if user
                    "@#{user.mention_name}"
                  else
                    "@#{link}"
                  end
                end

              when '#'
                if label
                  label
                else
                  channel = Lita::Room.find_by_id(link)
                  if channel
                    "\##{channel.name}"
                  else
                    "\##{link}"
                  end
                end

              when '!'
                "@#{link}" if ['channel', 'group', 'everyone'].include? link
              else
                link = link.gsub /^mailto:/, ''
                if label && !(link.include? label)
                  "#{label} (#{link})"
                else
                  label == nil ? link : label
                end
            end
          end
          message.gsub('&lt;', '<')
                 .gsub('&gt;', '>')
                 .gsub('&amp;', '&')

        end

        def channel
          data["channel"]
        end

        def thread
          data["thread_ts"]
        end

        def user_lookup( user_id )
          user = User.find_by_id( user_id )
          return if user

          User.create( user_id )
        end

        def dispatch_me_message(user)
          room = Lita::Room.find_by_id(channel)
          extensions = { timestamp: data["ts"], attachments: data["attachments"] }
          extensions[:thread_ts] = data["thread_ts"] if data["thread_ts"]
          source = SlackSource.new(user: user, room: room || channel, extensions: extensions)
          source.private_message! if channel && channel[0] == "D"
          message = Message.new(robot, body, source)
          message.command! if source.private_message?
          message.extensions[:slack] = extensions
          log.debug("Dispatching message to Lita from #{user.id}.")
          robot.receive(message)
        end

        def from_self?(user_id)
          user_id == robot_id
        end

        def handle_bot_change
          log.debug("Updating user data for bot.")
          UserCreator.create_user(SlackUser.from_data(data["bot"]), robot, robot_id)
        end

        def handle_channel_change
          log.debug("Updating channel data.")
          RoomCreator.create_room(SlackChannel.from_data(data["channel"]), robot)
        end

        def handle_error
          error = data["error"]
          code = error["code"]
          message = error["msg"]
          log.error("Error with code #{code} received from Slack: #{message}")
        end

        def handle_hello
          log.info("Connected to Slack.")
          robot.trigger(:connected)
        end

        def handle_message
          return unless supported_subtype?
          return if data["user"] == 'USLACKBOT'

          return if from_self?(data["user"])

          user = User.find_by_id(data["user"])
          if user.nil?
            user_data = API.new(robot.config.adapters.slack).user_info(data["user"])['user']
            user = User.create( user_id, user_data )
          end

          case data["subtype"]
          when "message_deleted"
            data.delete("previous_message")
            data.delete("blocks")
            robot.trigger(:message_deleted, data)
          when "message_changed"
            data.delete("previous_message")
            robot.trigger(:message_changed, data)
          else
            dispatch_me_message(user)
          end
        end

        def handle_reaction
          log.debug "#{type} event received from Slack"

          # find or create user
          user = User.find_by_id(data["user"]) || User.create(data["user"])

          # avoid processing reactions added/removed by self
          return if from_self?(data["user"])

          # find or create item_user
          item_user = User.find_by_id(data["item_user"]) || User.create(data["item_user"])

          # build a payload following slack convention for reactions
          payload = {
            user: user, name: data["reaction"], item_user: item_user,
            item: data["item"], event_ts: data["event_ts"]
          }

          # trigger the appropriate slack reaction event
          robot.trigger("slack_#{type}".to_sym, payload)
        end

        def handle_unknown
          unless data["reply_to"]
            log.debug("#{type} event received from Slack and will be ignored.")
          end
        end

        def handle_user_change
          log.debug("Updating user data.")
          UserCreator.create_user(SlackUser.from_data(data["user"]), robot, robot_id)
        end

        def log
          Lita.logger
        end

        # Types of messages Lita should dispatch to handlers.
        SUPPORTED_MESSAGE_SUBTYPES = %w(me_message message_deleted message_changed)

        def supported_subtype?
          subtype = data["subtype"]

          if subtype
            SUPPORTED_MESSAGE_SUBTYPES.include?(subtype)
          else
            true
          end
        end
      end
    end
  end
end
