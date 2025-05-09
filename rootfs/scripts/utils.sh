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

# Wait for the lock to become available
# args:
#   $1: branch
#   $2: queue_file
#   $3: ticket_id
#   $4: repository
#   $5: timeout (optional)
#   $6: start_time (optional)
wait_for_lock() {
	__branch=$1
	__queue_file=$2
	__ticket_id=$3
	__repository=$4
	__timeout=$5
	__start_time=${6:-$(date +%s)}

	__current_time=$(date +%s)
	__elapsed_time=$((__current_time - __start_time))

	# Check if we've exceeded the timeout
	if [ -n "$__timeout" ] && [ $__elapsed_time -ge $__timeout ]; then
		echo "[$__ticket_id] Timeout reached trying to obtain the lock after $__elapsed_time seconds"
		exit_failure_with_information $__branch $__repository
	fi

	update_branch $__branch

	# if we are not the first in line, spin
	if [ -s $__queue_file ]; then
		cur_lock=$(head -n 1 $__queue_file)
		if [ "$cur_lock" != "$__ticket_id" ]; then
			echo "[$__ticket_id] Waiting for lock - Current lock assigned to [$cur_lock] (elapsed time: $__elapsed_time seconds)"
			sleep 5
			wait_for_lock $__branch $__queue_file $__ticket_id $__repository $__timeout $__start_time
		fi
	else
		echo "[$__ticket_id] $__queue_file unexpectedly empty, continuing"
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

# Print information on how to unlock the mutex and exit with an error
# args:
#   $1: branch
#   $2: repository
exit_failure_with_information() {
	__branch=$1
	__repository=$2

	echo "If you are sure that no other process is using this mutex, you can delete the branch by running the following commands to clean up the mutex branch:"
	echo "The lock branch: $__branch exists in this repository: $__repository"
	echo "git push origin --delete $__branch"
	echo "git branch -D $__branch"
	exit 1
}