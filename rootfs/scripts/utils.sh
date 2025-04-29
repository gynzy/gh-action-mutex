# Set up the mutex repo
# args:
#   $1: repo_url
set_up_repo() {
	__repo_url=$1

	git init --quiet
	git config --local user.name "github-bot" --quiet
	git config --local user.email "github-bot@users.noreply.github.com" --quiet
	git remote remove origin 2>/dev/null || true
	git remote add origin "$__repo_url"
}

# Update the branch to the latest from the remote. Or checkout to an orphan branch
# args:
#   $1: branch
update_branch() {
	__branch=$1

	git switch --orphan gh-action-mutex/temp-branch-$(date +%s) --quiet
	git branch -D $__branch --quiet 2>/dev/null || true
	git fetch origin $__branch --quiet 2>/dev/null || true
	git checkout $__branch --quiet || git switch --orphan $__branch --quiet
}

# Add to the queue
# args:
#   $1: branch
#   $2: queue_file
#   $3: ticket_id
enqueue() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	__has_error=0

	echo "[$__ticket_id] Enqueuing to branch $__branch, file $__queue_file"

	update_branch $__branch

	touch $__queue_file

	# if we are not in the queue, add ourself to the queue
	if ! grep -qx "$__ticket_id" "$__queue_file" ; then
		echo "[$__ticket_id] Adding ourself to the queue file $__queue_file"
		echo "$__ticket_id" >> "$__queue_file"

		git add $__queue_file
		git commit -m "[$__ticket_id] Enqueue " --quiet

		set +e # allow errors
		git push --set-upstream origin $__branch --quiet
		__has_error=$((__has_error + $?))
		set -e
	fi

	if [ ! $__has_error -eq 0 ]; then
		sleep 1
		enqueue $@
	fi
}

# Cleanup mutex branch
# args:
#   $1: branch
#   $2: queue_file
#   $3: ticket_id
cleanup_mutex_branch() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3
	__cleanup_id="cleanup-$(date +%s)-$(( $RANDOM % 1000 ))"

	echo "[$__ticket_id] Attempting to clean up mutex branch $__branch"

	# Try to acquire cleanup lock using Git's atomic operations
	update_branch $__branch

	# Check if cleanup is already in progress by another process
	if grep -q "^CLEANUP_IN_PROGRESS:" "$__queue_file" 2>/dev/null; then
		echo "[$__ticket_id] Cleanup already in progress by another process, waiting..."
		sleep 5
		# Retry cleanup
		cleanup_mutex_branch $__branch $__queue_file $__ticket_id
		return
	fi

	# Mark cleanup in progress with our unique ID
	echo "CLEANUP_IN_PROGRESS:$__cleanup_id" > "$__queue_file"

	git add $__queue_file
	git commit -m "[$__ticket_id] Mark cleanup in progress" --quiet

	# Try to push - if this fails, another process might be cleaning up
	set +e # allow errors
	git push --set-upstream origin $__branch --quiet
	__push_result=$?
	set -e

	if [ ! $__push_result -eq 0 ]; then
		echo "[$__ticket_id] Failed to acquire cleanup lock, checking if another process is actually cleaning up..."

		# Pull the latest state to see if another job has the cleanup lock
		git fetch origin $__branch --quiet
		git reset --hard origin/$__branch --quiet

		# Check if cleanup is still in progress by another process
		if grep -q "^CLEANUP_IN_PROGRESS:" "$__queue_file" 2>/dev/null; then
			# Extract the timestamp from the cleanup ID to check how old it is
			__cleanup_timestamp=$(grep "^CLEANUP_IN_PROGRESS:" "$__queue_file" | sed -E 's/CLEANUP_IN_PROGRESS:cleanup-([0-9]+).*/\1/')
			__current_timestamp=$(date +%s)

			# If we can extract a timestamp and it's more than 5 minutes old, assume the cleanup job failed
			if [ -n "$__cleanup_timestamp" ] && [ $((__current_timestamp - __cleanup_timestamp)) -gt 300 ]; then
				echo "[$__ticket_id] Found stale cleanup lock (>5 minutes old), assuming previous cleanup job failed. Taking over cleanup..."
				# Continue with cleanup (don't return)
			else
				echo "[$__ticket_id] Another process is actively cleaning up. We will not cleanup ourselves..."
				return
			fi
		else
			echo "[$__ticket_id] No active cleanup lock found despite push failure. Retrying..."
			sleep 5
			# Retry cleanup
			cleanup_mutex_branch $__branch $__queue_file $__ticket_id
			return
		fi
	fi

	echo "[$__ticket_id] Acquired cleanup lock, waiting 10 seconds for others to observer the cleanup lock"
	sleep 10
	echo "[$__ticket_id] Proceeding with cleanup"

	# Create a new orphan branch to replace the current one
	git switch --orphan gh-action-mutex/temp-branch-$(date +%s) --quiet

	# Create an empty queue file
	touch $__queue_file

	git add $__queue_file
	git commit -m "[$__ticket_id] Reset mutex branch" --quiet

	# Force push to replace the branch
	git push -f --set-upstream origin HEAD:$__branch --quiet

	# Checkout the branch again
	git checkout $__branch --quiet || git switch --orphan $__branch --quiet

	echo "[$__ticket_id] Mutex branch cleanup completed"
}

# Wait for the lock to become available
# args:
#   $1: branch
#   $2: queue_file
#   $3: ticket_id
#   $4: start_time (optional, used for timeout calculation)
wait_for_lock() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3
	__start_time=${4:-$(date +%s)}
	__current_time=$(date +%s)
	__elapsed_time=$((__current_time - __start_time))

	# Check if we've exceeded the timeout
	if [ -n "$ARG_TIMEOUT" ] && [ $__elapsed_time -ge $ARG_TIMEOUT ]; then
		echo "[$__ticket_id] Timeout reached after $__elapsed_time seconds"

		if [ "$ARG_CLEANUP_MUTEX_ON_TIMEOUT" = "true" ]; then
			echo "[$__ticket_id] cleanup-mutex-on-timeout is enabled, cleaning up mutex branch and retrying"
			cleanup_mutex_branch $__branch $__queue_file $__ticket_id
			# Re-enqueue ourselves after cleanup
			enqueue $__branch $__queue_file $__ticket_id
			# Reset the start time for a new attempt
			wait_for_lock $__branch $__queue_file $__ticket_id $(date +%s)
			return
		else
			echo "[$__ticket_id] cleanup-mutex-on-timeout is disabled, exiting with error"
			exit 1
		fi
	fi

	update_branch $__branch

	# Check if cleanup is in progress
	if grep -q "^CLEANUP_IN_PROGRESS:" "$__queue_file" 2>/dev/null; then
		echo "[$__ticket_id] Cleanup in progress detected, resetting timeout counter"
		# Reset the start time to give the cleanup process time to complete
		wait_for_lock $__branch $__queue_file $__ticket_id $(date +%s)
		return
	fi

	# if we are not the first in line, spin
	if [ -s $__queue_file ]; then
		cur_lock=$(head -n 1 $__queue_file)
		if [ "$cur_lock" != "$__ticket_id" ]; then
			echo "[$__ticket_id] Waiting for lock - Current lock assigned to [$cur_lock] (elapsed time: $__elapsed_time seconds)"
			sleep 5
			wait_for_lock $__branch $__queue_file $__ticket_id $__start_time
		fi
	else
		echo "[$__ticket_id] $__queue_file unexpectedly empty, requeuing for the lock"
		# Requeue ourselves
		enqueue $__branch $__queue_file $__ticket_id
		wait_for_lock $__branch $__queue_file $__ticket_id $(date +%s)
	fi
}
# Remove from the queue, when locked by it or just enqueued
# args:
#   $1: branch
#   $2: queue_file
#   $3: ticket_id
dequeue() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3

	__has_error=0

	update_branch $__branch

	if [[ "$(head -n 1 $__queue_file)" == "$__ticket_id" ]]; then
		echo "[$__ticket_id] Unlocking"
		__message="[$__ticket_id] Unlock"
		# Remove top line
		sed -i '1d' "$__queue_file"
	elif grep -qx "$__ticket_id" "$__queue_file" ; then
		echo "[$__ticket_id] Dequeueing. We don't have the lock!"
		__message="[$__ticket_id] Dequeue"
		# Remove the matching line
		sed -i "/^${__ticket_id}$/d" $__queue_file
	else
		1>&2 echo "[$__ticket_id] Not in queue! Mutex file:"
		cat $__queue_file
		exit 1
	fi

	git add $__queue_file
	git commit -m "$__message" --quiet

	set +e # allow errors
	git push --set-upstream origin $__branch --quiet
	__has_error=$((__has_error + $?))
	set -e

	if [ ! $__has_error -eq 0 ]; then
		sleep 1
		dequeue $@
	fi
}
