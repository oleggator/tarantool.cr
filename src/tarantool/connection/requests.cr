require "../constants"

module Tarantool
  class Connection
    module Requests
      # Ping Tarantool and return elapsed time.
      #
      # ```
      # db.ping # => 00:00:00.000181477
      # ```
      def ping
        Time.measure do
          send(CommandCode::Ping)
        end
      end

      # Send AUTHORIZATION request.
      #
      # From Tarantool docs: "Authentication in Tarantool is optional, if no authentication is performed, session user is ‘guest’. The instance responds to authentication packet with a standard response with 0 tuples."
      #
      # ```
      # db.authenticate("guest").success?          # => true
      # db.authenticate("john", "secret").success? # => true
      # ```
      def authenticate(username : String, password : String = "")
        salt = Base64.decode(@encoded_salt)[0, 20]

        step_1 = Digest::SHA1.new.tap(&.update(password)).final
        step_2 = Digest::SHA1.new.tap(&.update(step_1)).final
        step_3 = Digest::SHA1.new.tap(&.update(salt)).tap(&.update(step_2)).final
        scramble = step_1.map_with_index { |byte, i| byte ^ step_3[i] }.to_slice

        send(CommandCode::Auth, {
          Key::Username.value => username,
          Key::Tuple.value    => ["chap-sha1", scramble],
        })
      end

      # Send SELECT request.
      #
      # From Tarantool docs: "Find tuples matching the search pattern."
      #
      # ```
      # db.select(999, 0, {1})                 # Select {1} from space #999 by index #0
      # db.select("examples", "primary", {1})  # ditto
      # db.select(:examples, :wage, {50}, :>=) # Select with wage >= 50
      # ```
      #
      # Iterators mapping (string or symbol value is accepted):
      #
      # * **Equal:** `eq` *or* `==`
      # * **Reversed equal:** `reveq` *or* `==<`
      # * **All:** `all` *or* `*`
      # * **Less than:** `lt` *or* `<`
      # * **Less than or equal:** `lte` *or* `<=`
      # * **Greater than or equal:** `gte` *or* `>=`
      # * **Greater than:** `gt` *or* `>`
      # * **Bits all set:** `bitall` *or* `&=`
      # * **Bits any set:** `bitany` *or* `&`
      # * **Rtree overlaps:** `overlaps` *or* `&&`
      # * **Rtree neighbor:** `neighbor` *or* `<->`
      #
      # Also see [iterators documentation](https://tarantool.io/en/doc/1.9/book/box/box_index.html#box-index-iterator-types).
      def select(
        space : Int | String | Symbol,
        index : Int | String | Symbol,
        key : Tuple | Array,
        iterator : Iterator | Symbol | String = Iterator::Equal,
        offset = 0,
        limit = 2 ** 30
      )
        convert_space_and_index

        unless iterator.is_a?(Iterator)
          iterator = convert_iterator(iterator)
        end

        send(CommandCode::Select, {
          Key::SpaceID.value  => space,
          Key::IndexID.value  => index,
          Key::Limit.value    => limit,
          Key::Offset.value   => offset,
          Key::Iterator.value => iterator.value,
          Key::Key.value      => key,
        })
      end

      # Same as `#select` but with primary index and limit equal to 1.
      def get(space, key)
        self.select(space, 0, key, limit: 1)
      end

      # Send INSERT request.
      #
      # From Tarantool docs: "Inserts tuple into the space, if no tuple with same unique keys exists. Otherwise throw duplicate key error."
      #
      # ```
      # db.insert(999, {1, "vlad"})       # Insert into space #999 value {1, "vlad"}
      # db.insert(:examples, {1, "vlad"}) # ditto
      # ```
      def insert(space : Int | String | Symbol, tuple : Tuple | Array)
        convert_space

        send(CommandCode::Insert, {
          Key::SpaceID.value => space,
          Key::Tuple.value   => tuple,
        })
      end

      # Send REPLACE request.
      #
      # From Tarantool docs: "Insert a tuple into the space or replace an existing one."
      #
      # ```
      # db.replace(999, {1, "faust"}) # Replace in space #999 value {1, "vlad"} with {1, "faust"} or insert if not exists
      # ```
      def replace(space : Int | String | Symbol, tuple : Tuple | Array)
        convert_space

        send(CommandCode::Replace, {
          Key::SpaceID.value => space,
          Key::Tuple.value   => tuple,
        })
      end

      # Send UPDATE request.
      #
      # From Tarantool docs: "Update a tuple. It is an error to specify an argument of a type that differs from the expected type."
      #
      # ```
      # db.update(999, 0, {1}, [{":", 1, 0, 0, "vlad"}]) # Append "vlad" to "faust", resulting in "vladfaust"
      # ```
      def update(
        space : Int | String | Symbol,
        index : Int | String | Symbol,
        key : Tuple | Array,
        tuple : Array # It should really be named "ops"
      )
        convert_space_and_index

        send(CommandCode::Update, {
          Key::SpaceID.value => space,
          Key::IndexID.value => index,
          Key::Key.value     => key,
          Key::Tuple.value   => tuple,
        })
      end

      # Send DELETE request.
      #
      # From Tarantool docs: "Delete a tuple."
      #
      # ```
      # db.delete(999, 1, {"vladfaust"})           # Will delete the entry
      # db.delete(:examples, :name, {"vladfaust"}) # ditto
      # ```
      def delete(
        space : Int | String | Symbol,
        index : Int | String | Symbol,
        key : Tuple | Array
      )
        convert_space_and_index

        send(CommandCode::Delete, {
          Key::SpaceID.value => space,
          Key::IndexID.value => index,
          Key::Key.value     => key,
        })
      end

      # Send CALL request.
      #
      # From Tarantool docs: "Call a stored function, returning an array of tuples."
      #
      # ```
      # db.call(:my_func)
      # ```
      def call(function : String | Symbol, args : Tuple | Array = [] of MessagePack::Type)
        send(CommandCode::Call, {
          Key::FunctionName.value => function,
          Key::Tuple.value        => args,
        })
      end

      # Send EVAL request.
      #
      # From Tarantool docs: "Evaulate Lua expression."
      #
      # ```
      # db.eval("local a, b = ... ; return a + b", {1, 2}) # Will return response with [3] in its body
      # ```
      def eval(expression : String, args : Tuple | Array = [] of MessagePack::Type)
        send(CommandCode::Eval, {
          Key::Expression.value => expression,
          Key::Tuple.value      => args,
        })
      end

      # Send UPSERT request.
      #
      # From Tarantool docs: "Update tuple if it would be found elsewhere try to insert tuple. Always use primary index for key."
      #
      # ```
      # db.eval(999, {1, "vlad"}, ["=", 1, "vladfaust"]) # Insert {1, "vlad"} or replace its name with "vladfaust"
      # ```
      def upsert(space : Int | String | Symbol, tuple : Tuple | Array, ops : Array)
        convert_space

        send(CommandCode::Upsert, {
          Key::SpaceID.value => space,
          Key::Tuple.value   => tuple,
          Key::Ops.value     => ops,
        })
      end

      # Get space ID by its *name*. Call `#parse_schema` beforehand.
      def space_name_to_id(name : String)
        @schema[name]?.try &.[:id] || raise ArgumentError.new("Space \"#{name}\" is not found in current schema. Try #parse_schema beforehand")
      end

      # Get index ID by *space_id* and *index_name*. Call `#parse_schema` beforehand.
      def index_name_to_id(space_id : Int, index_name : String)
        space_name = @schema.find { |name, values| values[:id] == space_id }.try &.[0] || raise ArgumentError.new("Space ##{space_id} is not found in current schema. Try #parse_schema beforehand")
        index_name_to_id(space_name, index_name)
      end

      # Get index ID by *space_name* and *index_name*. Call `#parse_schema` beforehand.
      def index_name_to_id(space_name : String, index_name : String)
        space = @schema[space_name]? || raise ArgumentError.new("Space \"#{space_name}\" is not found in current schema. Try #parse_schema beforehand")
        space.not_nil![:indexes][index_name] || raise ArgumentError.new("Index \"#{index_name}\" is not found in space \"#{space_name}\". Try #parse_schema beforehand")
      end

      # :nodoc:
      IteratorMap = {
        {:eq, :==}          => Iterator::Equal,
        {:reveq, :"==<"}    => Iterator::ReversedEqual,
        {:all, :*}          => Iterator::All,
        {:lt, :<}           => Iterator::LessThan,
        {:lte, :<=}         => Iterator::LessThanOrEqual,
        {:gte, :>=}         => Iterator::GreaterThanOrEqual,
        {:gt, :>}           => Iterator::GreaterThan,
        {:bitall, :"&="}    => Iterator::BitsAllSet,
        {:bitany, :&}       => Iterator::BitsAnySet,
        {:overlaps, :"&&"}  => Iterator::RtreeOverlaps,
        {:neighbor, :"<->"} => Iterator::RtreeNeighbor,
      }

      private macro convert_iterator(which)
        {% begin %}
          case {{which}}
          {% for k, v in IteratorMap %}
          when {{(k.map(&.stringify) + k.map(&.id.stringify.stringify)).join(", ").id}}
            {{v.id}}
          {% end %}
          else
            raise "Unknown iterator #{{{which}}}"
          end
        {% end %}
      end

      private macro convert_space
        if space.is_a?(String) || space.is_a?(Symbol)
          space = space_name_to_id(space.to_s)
        end
      end

      private macro convert_space_and_index
        space_name : String? = nil

        if space.is_a?(String) || space.is_a?(Symbol)
          space_name = space.to_s
          space = space_name_to_id(space.to_s)
        end

        if index.is_a?(String) || index.is_a?(Symbol)
          index = index_name_to_id(space_name || space, index.to_s)
        end
      end
    end
  end
end
