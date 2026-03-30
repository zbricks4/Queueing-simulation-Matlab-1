classdef ServiceQueue < handle
    % ServiceQueue Simulation object that keeps track of customer arrivals,
    % departures, and service.
    % The default properties are for time measured in hours.

    properties (SetAccess = public)
        
        % ArrivalRate - Customers arrive according to a Poisson process.
        % The inter-arrival time is exponentially distributed with a rate
        % parameter of ArrivalRate.
        % The default is 10 per hour (mean inter-arrival time of 6 minutes).
        ArrivalRate = 10;

        % DepartureRate - When a customer arrives, the time it takes for
        % them to be served is exponentially distributed with a rate
        % parameter of DepartureRate.
        % The default is 12 per hour (mean service time of 5 minutes).
        DepartureRate = 12;

        % NumServers - How many identical serving stations are available.
        NumServers = 1;

        % LogInterval - Approximately how many time units between log
        % entries.  Log events are scheduled so that when one log entry is
        % recorded, the next is scheduled for the current time plus this
        % interval.
        % The default is 1/60 of an hour (1 minute)
        LogInterval = 1/60;
    
    end

    properties (SetAccess = private)
        % Time - Current time.
        Time = 0;

        % InterArrivalDist - Function handle that samples the time until
        % the next arrival.
        InterArrivalDist;

        % ServiceDist - Function handle that samples the service time.
        ServiceDist;

        % ServerAvailable - Row vector of boolean values, initial all true.
        % ServerAvailable(j) is set to false when serving station j begins
        % serving a customer, and is set to true when that service is
        % complete.
        ServerAvailable;

        % Servers - Cell array row vector. Entries are initially empty.
        % When service station j begins serving a Customer, the Customer
        % object is stored in Servers{j}.
        Servers;

        % Events - PriorityQueue object that holds all active Event objects
        % of all types. All events have a Time property that specifies
        % when they occur. The next event is the one with the least Time,
        % and can be popped from Events.
        Events;

        % Waiting - Cell array row vector of Customer objects. Initially
        % empty. All arriving Customers are placed at the end of this
        % vector. When a serving station is available, the first Customer
        % is removed from Waiting and moved to the corresponding slot in
        % Servers.
        Waiting = {};

        % Served - Cell array row vector of Customer objects. Initially
        % empty. When a Customer's service is complete, the Customer
        % object is moved from its slot in Servers to the end of Served.
        Served = {};

        % Log - Table of log entries. Its columns are:
        % * Time - Time of the log entry
        % * NumWaiting - How many customers are currently waiting
        % * NumInService - How many are currently being served
        % * NumServed -  How many have been served
        Log = table(Size=[0, 4], ...
            VariableNames=...
            {'Time', 'NumWaiting', 'NumInService', 'NumServed'}, ...
            VariableTypes=...
            {'double', 'int64', 'int64', 'int64'});
    
    end

    methods

        function obj = ServiceQueue(KWArgs)
            % ServiceQueue Constructor. Public properties can be specified
            % as named arguments.

            arguments
                KWArgs.?ServiceQueue;
            end

            fnames = fieldnames(KWArgs);
            for ifield = 1:length(fnames)
                s = fnames{ifield};
                obj.(s) = KWArgs.(s);
            end

            % Initialize the private properties of this instance.
            % Use function handles instead of makedist/random so no extra
            % toolbox is required.
            obj.InterArrivalDist = @() (-log(rand) / obj.ArrivalRate);
            obj.ServiceDist = @() (-log(rand) / obj.DepartureRate);

            obj.ServerAvailable = repelem(true, obj.NumServers);
            obj.Servers = cell([1, obj.NumServers]);

            % Events has to be initialized in the constructor.
            obj.Events = PriorityQueue({}, @(x) x.Time);

            schedule_event(obj, RecordToLog(obj.LogInterval));
        end

        function obj = run_until(obj, MaxTime)
            % run_until Event loop.
            % 
            % obj = run_until(obj, MaxTime) Repeatedly handle the next
            % event until the current time is at least MaxTime.

            while obj.Time <= MaxTime
                handle_next_event(obj)
            end
        end

        function schedule_event(obj, event)
            % schedule_event Add an object to the event queue.

            assert(event.Time >= obj.Time, ...
                "Event happens in the past");
            push(obj.Events, event);
        end

        function handle_next_event(obj)
            % handle_next_event Pop the next event and use the visitor
            % mechanism on it to do something interesting.

            assert(~is_empty(obj.Events), ...
                "No unhandled events");
            event = pop_first(obj.Events);
            assert(event.Time >= obj.Time, ...
                "Event happens in the past");

            % Update the current time to match the event that just
            % happened.
            obj.Time = event.Time;

            % This calls the event's visit() method, passing this service
            % queue object as an argument.
            visit(event, obj);
        end

        function handle_arrival(obj, arrival)
            % handle_arrival Handle an Arrival event.
            %
            % handle_arrival(obj, arrival) - Handle an Arrival event. Add
            % the Customer in the arrival object to the queue's internal
            % state. Create a new Arrival event and add it to the event
            % list.

            % Record the current time in the Customer object as its arrival
            % time.
            c = arrival.Customer;
            c.ArrivalTime = obj.Time;

            % The Customer is appended to the list of waiting customers.
            obj.Waiting{end+1} = c;

            % Construct the next Customer that will arrive.
            next_customer = Customer(c.Id + 1);
            
            % It will arrive after a random time sampled from
            % obj.InterArrivalDist.
            inter_arrival_time = obj.InterArrivalDist();

            % Build an Arrival instance that says that the next customer
            % arrives at the randomly determined time.
            next_arrival = ...
                Arrival(obj.Time + inter_arrival_time, next_customer);
            schedule_event(obj, next_arrival);

            % Check to see if any customers can advance.
            advance(obj);
        end

        function handle_departure(obj, departure)
            % handle_departure Handle a departure event.

            % This is which service station experiences the departure.
            j = departure.ServerIndex;

            assert(~obj.ServerAvailable(j), ...
                "Service station j must be occupied");
            assert(obj.Servers{j} ~= false, ...
                "There must be a customer in service station j");
            customer = obj.Servers{j};

            % Record the event time as the departure time for this
            % customer.
            customer.DepartureTime = departure.Time;

            % Add this Customer object to the end of Served.
            obj.Served{end+1} = customer;

            % Empty this service station and mark that it is available.
            obj.Servers{j} = false;
            obj.ServerAvailable(j) = true;

            % Check to see if any customers can advance.
            advance(obj);
        end

        function begin_serving(obj, j, customer)
            % begin_serving Begin serving the given customer at station j.
            % This is a helper method for advance().

            % Record the current time as the time that service began for
            % this customer.
            customer.BeginServiceTime = obj.Time;

            % Store the Customer in slot j of Servers and mark that station
            % j is no longer available.
            obj.Servers{j} = customer;
            obj.ServerAvailable(j) = false;

            % Sample ServiceDist to get the time it will take to serve this
            % customer.
            service_time = obj.ServiceDist();

            % Schedule a Departure event so that after the service time,
            % the customer at station j departs.
            obj.schedule_event(Departure(obj.Time + service_time, j));
        end

        function advance(obj)
            % advance Check to see if a waiting customer can advance.

            while ~isempty(obj.Waiting)
                [x, j] = max(obj.ServerAvailable);
               
                if x
                    customer = obj.Waiting{1};
                    obj.Waiting(1) = [];
                    begin_serving(obj, j, customer);
                else
                    break;
                end
            end
        end

        function handle_record_to_log(obj, ~)
            % handle_record_to_log Handle a RecordToLog event

            % Record a log entry.
            record_log(obj);

            % Schedule the next RecordToLog event to happen after
            % LogInterval time.
            schedule_event(obj, RecordToLog(obj.Time + obj.LogInterval));
        end

        function n = count_customers_in_system(obj)
            % count_customers_in_system Return how many customers are
            % currently in the system, including those waiting and those
            % being served.

            NumWaiting = length(obj.Waiting);
            NumInService = obj.NumServers - sum(obj.ServerAvailable);
            n = NumWaiting + NumInService;
        end

        function record_log(obj)
            % record_log Record a summary of the service queue state.

            NumWaiting = length(obj.Waiting);
            NumInService = obj.NumServers - sum(obj.ServerAvailable);
            NumServed = length(obj.Served);

            % This is how to add a row to the end of a table.
            obj.Log(end+1, :) = {obj.Time, NumWaiting, NumInService, NumServed};
        end
    end
end
 
% MATLAB-ism: The notation 
% 
%   classdef ServiceQueue < handle
% 
% makes ServiceQueue a subclass of handle, which means that this is a
% "handle" class, so instances have "handle" semantics. When you assign an
% instance to a variable, as in
%
%   q1 = ServiceQueue()
%   q2 = q1
%
% a handle (or reference) to the object is assigned rather than an
% independent copy. That is, q1 and q2 are handles to the same object.
% Changes made using q1 will affect q2, and vice-versa.
%
% In contrast, classes that aren't derived from handle are "value" classes.
% When you assign an instance to a variable, an independent copy is made.
% This is MATLAB's usual array behavior:
%
%  u = [1,2,3];
%  v = u;
%  v(1) = 10;
%
% After the above, u is still [1,2,3] and v is [10,2,3] because the
% assignment v = u copies the array. The change to v(1) doesn't affect the
% copy in u.
%
% Importantly, copies of value objects are made when they are passed to
% functions.
%
% Handle semantics are used for this simulation, so that methods are able
% to change the state of a ServiceQueue object. That is, something like
%
%  q = ServiceQueue()
%  handle_next_event(q)
%
% creates a ServiceQueue object and calls a method that changes its state.
% If ServiceQueue was a value class, the instance would be copied when
% passed to the handle_next_event method, and no changes could be made to
% the copy stored in the variable q.