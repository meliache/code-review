;;; code-review-github.el --- Github API functions -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Wanderson Ferreira
;;
;; Author: Wanderson Ferreira <https://github.com/wandersoncferreira>
;; Maintainer: Wanderson Ferreira <wand@hey.com>
;; Version: 0.0.1
;; Homepage: https://github.com/wandersoncferreira/code-review
;;
;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;;  This library is an interface with Github REST API and GraphQL API.
;;
;;; Code:

(require 'ghub)
(require 'deferred)
(require 'code-review-core)
(require 'code-review-db)
(require 'a)

(defclass code-review-github-repo (code-review-db-pullreq)
  ((callback            :initform nil)))

(defgroup code-review-github nil
  "Interact with GitHub REST and GraphQL APIs."
  :group 'code-review
  :link '(custom-group-link 'code-review-gitlab))

(defcustom code-review-github-host "api.github.com"
  "Host for the GitHub api if you use the hosted version of GitHub."
  :group 'code-review-github
  :type 'string)

(defconst code-review-github-diffheader '(("Accept" . "application/vnd.github.v3.diff"))
  "Header for requesting diffs from GitHub.")

(defconst code-review-github-token-scopes '(repo)
  "Only repo scope needed to read PRs and submit reviews.")

;; vars
(defvar code-review-log-file)

(defun code-review--log (origin msg)
  "Log MSG from ORIGIN to error file."
  (with-temp-file code-review-log-file
    (when (not (file-exists-p code-review-log-file))
      (write-file code-review-log-file))
    (insert-file-contents code-review-log-file)
    (goto-char (point-max))
    (insert ?\n)
    (insert (current-time-string))
    (insert " - ")
    (insert origin)
    (insert " - ")
    (insert msg)
    (insert ?\n)))

(defun code-review-github-errback (&rest m)
  "Error callback, displays the error message M."
  (let-alist m
    (code-review--log
     "code-review-github-errback"
     (prin1-to-string m))
    (let* ((status (-second-item .error)))
      (cond
       ((= status 422)
        (let ((errors (string-join
                       (a-get (-third-item .error) 'errors)
                       " AND "))
              (msg (string-trim (a-get (-third-item .error) 'message))))
          (message "Errors: %S" (if (string-empty-p errors)
                                    msg
                                  (string-join (list msg errors) ". ")))))
       ((= status 404)
        (message "Provided URL Not Found"))
       ((= status 401)
        (message "Bad credentials. Documentation to how to setup credentials
https://github.com/wandersoncferreira/code-review#configuration"))
       (t
        (message "Unknown error talking to Github: %s" m))))))

(cl-defmethod code-review-core-pullreq-diff ((github code-review-github-repo) callback)
  "Get PR diff from GITHUB, run CALLBACK after answer."
  (let ((owner (oref github owner))
        (repo (oref github repo))
        (num (oref github number)))
    (ghub-get (format "/repos/%s/%s/pulls/%s" owner repo num)
              nil
              :unpaginate t
              :headers code-review-github-diffheader
              :auth 'code-review
              :host code-review-github-host
              :callback callback
              :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-diff-deferred ((github code-review-github-repo))
  "Get PR diff from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-pullreq-diff
     github
     (apply-partially
      (lambda (d v &rest _)
        (deferred:callback-post d v))
      d))
    d))

(cl-defmethod code-review-core-commit-diff ((github code-review-github-repo) callback)
  "Get PR diff from GITHUB, run CALLBACK after answer."
  (let ((owner (oref github owner))
        (repo (oref github repo))
        (sha (oref github sha)))
    (ghub-get (format "/repos/%s/%s/commits/%s" owner repo sha)
              nil
              :unpaginate t
              :headers code-review-github-diffheader
              :auth 'code-review
              :host code-review-github-host
              :callback callback
              :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-commit-diff-deferred ((github code-review-github-repo))
  "Get PR diff from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-commit-diff
     github
     (apply-partially
      (lambda (d v &rest _)
        (deferred:callback-post d v))
      d))
    d))

(cl-defmethod code-review-core-pullreq-infos ((github code-review-github-repo) callback)
  "Get PR details from GITHUB and dispatch to CALLBACK."
  (let* ((repo (oref github repo))
         (owner (oref github owner))
         (num (oref github number))
         (query
          (format "query {
  repository(name: \"%s\", owner: \"%s\") {
    pullRequest(number:%s){
      id
      headRef { target{ oid } }
      baseRefName
      headRefName
      isDraft
      databaseId
      number
      createdAt
      updatedAt
      latestOpinionatedReviews(first: 100) {
         nodes {
           author {
             login
           }
           createdAt
           state
         }
       }
      reviewRequests(first:100){
         nodes {
           asCodeOwner
           requestedReviewer {
             __typename
             ... on User {
               login
               name
             }
           }
         }
       }
      files(first:100) {
        nodes {
          path
          additions
          deletions
        }
      }
      milestone {
        title
        progressPercentage
      }
      labels(first: 10) {
        nodes {
          name
          color
        }
      }
      assignees(first: 15) {
        nodes {
          name
          login
        }
      }
      projectCards(first: 10) {
        nodes {
          project {
            name
          }
        }
      }
      suggestedReviewers {
        reviewer {
          name
          login
        }
      }
      commits(first: 100) {
        totalCount
        nodes {
          commit {
            abbreviatedOid
            message
          }
        }
      }
      title
      state
      bodyText
      reactions(first:50){
        nodes {
          id
          content
        }
      }
      comments(first:50) {
        nodes {
          typename:__typename
          reactions(first:50){
            nodes {
              id
              content
            }
          }
          author {
            login
          }
          databaseId
          bodyText
          createdAt
          updatedAt
        }
      }
      reviews(first: 50) {
        nodes {
          typename:__typename
          author { login }
          bodyText
          state
          createdAt
          databaseId
          updatedAt
          comments(first: 50) {
            nodes {
              createdAt
              updatedAt
              bodyText
              originalPosition
              diffHunk
              position
              outdated
              path
              databaseId
              reactions(first:50){
                nodes {
                  id
                  content
                }
              }
            }
          }
        }
      }
    }
  }
}
" repo owner (if (numberp num)
                 num
               (string-to-number num)))))
    (ghub-graphql query
                  nil
                  :auth 'code-review
                  :host code-review-github-host
                  :callback callback
                  :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-infos-deferred ((github code-review-github-repo))
  "Get PR infos from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-pullreq-infos
     github
     (apply-partially (lambda (d v &rest _)
                        (deferred:callback-post d v))
                      d))
    d))

(cl-defmethod code-review-core-get-labels ((github code-review-github-repo))
  "Get labels from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/labels"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       (a-get l 'name))
     resp)))

(cl-defmethod code-review-core-set-labels ((github code-review-github-repo) callback)
  "Set labels for your pr at GITHUB and call CALLBACK."
  (let ((url (format "/repos/%s/%s/issues/%s/labels"
                     (oref github owner)
                     (oref github repo)
                     (oref github number)))
        (req-fn (if (oref github labels)
                    #'ghub-post
                  #'ghub-put)))
    (funcall req-fn url
             nil
             :payload (a-alist 'labels (or (-map (lambda (x)
                                                   (a-get x 'name))
                                                 (oref github labels))
                                           []))
             :auth 'code-review
             :errorback #'code-review-github-errback
             :callback (lambda (&rest _) (funcall callback)))))

(cl-defmethod code-review-core-get-assignees ((github code-review-github-repo))
  "Get labels from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/assignees"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       (a-get l 'login))
     resp)))

(cl-defmethod code-review-core-set-assignee ((github code-review-github-repo) callback)
  "Set assignee to your PR in GITHUB and call CALLBACK."
  (ghub-post (format "/repos/%s/%s/issues/%s/assignees"
                     (oref github owner)
                     (oref github repo)
                     (oref github number))
             nil
             :auth 'code-review
             :payload (a-alist 'assignees (-map (lambda (it)
                                                  (a-get it 'login))
                                                (oref github assignees)))
             :errorback #'code-review-github-errback
             :callback (lambda (&rest _) (funcall callback))))

(cl-defmethod code-review-core-get-milestones ((github code-review-github-repo))
  "Get milestones from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/milestones"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       `(,(a-get l 'title) . ,(a-get l 'number)))
     resp)))

(cl-defmethod code-review-core-set-milestone ((github code-review-github-repo) callback)
  "Set milestone for a pullreq in GITHUB and call CALLBACK."
  (ghub-patch (format "/repos/%s/%s/issues/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'milestone (a-get (oref github milestones) 'number))
              :errorback #'code-review-github-errback
              :callback (lambda (res &rest _)
                          (if (a-get res 'milestone)
                              (funcall callback)
                            (message "You cannot set this Milestone. Verify if the milestone exist in Github.")))))

(cl-defmethod code-review-core-set-title ((github code-review-github-repo) callback)
  "Set title for a pullreq in GITHUB and call CALLBACK."
  (ghub-patch (format "/repos/%s/%s/pulls/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'title (oref github title))
              :errorback #'code-review-github-errback
              :callback (lambda (&rest _) (funcall callback))))

(cl-defmethod code-review-core-set-description ((github code-review-github-repo) callback)
  "Set description for a pullreq in GITHUB and call CALLBACK."
  (ghub-patch (format "/repos/%s/%s/pulls/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'body (oref github description))
              :errorback #'code-review-github-errback
              :callback (lambda (&rest _) (funcall callback))))

(cl-defmethod code-review-core-merge ((github code-review-github-repo) strategy)
  "Merge a PR in GITHUB using a STRATEGY."
  (ghub-put (format "/repos/%s/%s/pulls/%s/merge"
                    (oref github owner)
                    (oref github repo)
                    (oref github number))
            nil
            :auth 'code-review
            :payload (a-alist 'commit_title (oref github title)
                              'commit_message (oref github description)
                              'sha (oref github sha)
                              'merge_method strategy)
            :errorback #'code-review-github-errback))

(cl-defmethod code-review-core-set-reaction ((github code-review-github-repo) context-name comment-id reaction)
  "Set REACTION in GITHUB pullreq COMMENT-ID given a CONTEXT-NAME e.g. issue, pr, discussion."
  (let ((path (pcase context-name
                ("pr-description"
                 (format "issues/%s/reactions" (oref github number)))
                ("comment"
                 (format "issues/comments/%s/reactions" comment-id))
                ("code-comment"
                 (format "pulls/comments/%s/reactions" comment-id))))
        (r (pcase reaction
             ("thumbs_up" "+1")
             ("thumbs_down" "-1")
             (_ reaction))))
    (ghub-post (format "/repos/%s/%s/%s"
                       (oref github owner)
                       (oref github repo)
                       path)
               nil
               :auth 'code-review
               :payload (a-alist 'content r))))

(cl-defmethod code-review-core-delete-reaction ((github code-review-github-repo) context-name comment-id reaction-id)
  "Delete REACTION-ID in GITHUB pullreq COMMENT-ID given a CONTEXT-NAME e.g. issue, pr, discussion."
  (let ((path (pcase context-name
                ("pr-description"
                 (format "issues/%s/reactions/%s" (oref github number) reaction-id))
                ("comment"
                 (format "issues/comments/%s/reactions/%s" comment-id reaction-id))
                ("code-comment"
                 (format "pulls/comments/%s/reactions/%s" comment-id reaction-id)))))
    (ghub-delete (format "/repos/%s/%s/%s"
                         (oref github owner)
                         (oref github repo)
                         path)
                 nil
                 :auth 'code-review)))

(defclass code-review-submit-github-replies ()
  ((pr      :initform nil)
   (replies :initform nil
            :type (satisfies
                   (lambda (it)
                     (-all-p #'code-review-submit-reply-p it))))))

(cl-defmethod code-review-core-send-replies ((replies code-review-submit-github-replies) callback)
  "Submit replies to review comments inline given REPLIES and a CALLBACK fn."
  (let ((pr (oref replies pr)))
    (deferred:$
      (deferred:parallel
        (-map
         (lambda (reply)
           (lambda ()
             (ghub-post (format "/repos/%s/%s/pulls/%s/comments/%s/replies"
                                (oref pr owner)
                                (oref pr repo)
                                (oref pr number)
                                (oref reply reply-to-id))
                        nil
                        :payload (a-alist 'body (oref reply body))
                        :headers code-review-github-diffheader
                        :auth 'code-review
                        :host code-review-github-host
                        :callback (lambda (&rest _))
                        :errorback #'code-review-github-errback)))
         (oref replies replies)))

      (deferred:nextc it
        (lambda (_x)
          (funcall callback)))

      (deferred:error it
        (lambda (err)
          (message "Got an error from the Github Reply API %S!" err))))))

(defclass code-review-submit-github-review ()
  ((state :initform nil)
   (pr :initform nil)
   (local-comments :initform nil
                   :type (satisfies
                          (lambda (it)
                            (-all-p #'code-review-submit-local-coment-p it))))
   (feedback :initform nil)))

(cl-defmethod code-review-core-send-review ((review code-review-submit-github-review) callback)
  "Submit review comments given REVIEW and a CALLBACK fn."
  (let* ((pr (oref review pr))
         (payload (a-alist 'event (oref review state)
                           'commit_id (oref pr sha)))
         (payload (if (oref review feedback)
                      (a-assoc payload 'body (oref review feedback))
                    payload))
         (payload (if (oref review local-comments)
                      (a-assoc payload 'comments (--sort
                                                  (< (a-get it 'position)
                                                     (a-get other 'position))
                                                  (-map
                                                   (lambda (c)
                                                     `((path . ,(oref c path))
                                                       (position . ,(oref c position))
                                                       (body . ,(oref c body))))
                                                   (oref review local-comments))))
                    payload)))
    (ghub-post (format "/repos/%s/%s/pulls/%s/reviews"
                       (oref pr owner)
                       (oref pr repo)
                       (oref pr number))
               nil
               :auth 'code-review
               :payload payload
               :host code-review-github-host
               :errorback #'code-review-github-errback
               :callback callback)))

(cl-defmethod code-review-core-get-assinable-users ((github code-review-github-repo))
  "Get a list of assignable users for current PR in GITHUB."
  (let ((infos (oref github raw-infos))
        (query "query($repo_owner:String!, $repo_name:String!, $cursor:String) {
   repository(owner: $repo_owner, name: $repo_name) {
     assignableUsers(first: 100, after: $cursor) {
       pageInfo {
         endCursor
         hasNextPage
       }
       nodes {
         id
         login
         name
       }
     }
   }
 }"))
    (if-let (users (a-get infos 'assignable-users))
        users
      (let ((has-next-page t)
            cursor res)
        (while has-next-page
          (let ((graphql-res (ghub-graphql query
                                           `((repo_owner . ,(oref github owner))
                                             (repo_name . ,(oref github repo))
                                             (cursor . ,cursor))
                                           :auth 'code-review
                                           :host code-review-github-host)))
            (let-alist graphql-res
              (setq has-next-page .data.repository.assignableUsers.pageInfo.hasNextPage
                    cursor .data.repository.assignableUsers.pageInfo.endCursor
                    res (append res .data.repository.assignableUsers.nodes)))))
        (oset github raw-infos (a-assoc infos 'assignable-users res))
        (code-review-db-update github)
        res))))

(cl-defmethod code-review-core-request-review ((github code-review-github-repo) user-ids callback)
  "Request review for your GITHUB PR from USER-IDS and call CALLBACK afterward."
  (let ((query "mutation($input: RequestReviewsInput!) {
  requestReviews(input: $input) {
    pullRequest {
      id
    }
  }
}
")
        (pr-id (a-get (oref github raw-infos) 'id)))
    (ghub-graphql query
                  `((input . ((pullRequestId . ,pr-id)
                              (userIds . ,user-ids))))
                  :auth 'code-review
                  :host code-review-github-host
                  :callback (lambda (&rest _)
                              (message "Review requested successfully!")
                              (funcall callback))
                  :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-new-issue ((github code-review-github-repo) body title callback)
  "Create a new issue in GITHUB given a BODY and TITLE and call CALLBACK."
  (ghub-post (format "/repos/%s/%s/issues"
                     (oref github owner)
                     (oref github repo))
             nil
             :auth 'code-review
             :payload (a-alist 'body body 'title title)
             :errorback #'code-review-github-errback
             :callback callback))

(cl-defmethod code-review-github-promote-comment-to-new-issue-data ((github code-review-github-repo))
  "Promote comment to new issue in GITHUB."
  (let ((section (magit-current-section)))
    (with-slots (value) section
      (let* ((orig-identifier (cond
                               ((code-review-code-comment-section-p section)
                                "discussion_r")
                               ((code-review-comment-section-p section)
                                (pcase (oref value typename)
                                  ("IssueComment" "issuecomment-")
                                  ("PullRequestReview" "pullrequestreview-")))
                               (t
                                (error "Promote comment to issue not supported for this type of comment"))))
             (reference-link (format "https://github.com/%s/%s/issues/%s#%s%s"
                                     (oref github owner)
                                     (oref github repo)
                                     (oref github number)
                                     orig-identifier
                                     (oref value id)))
             (title (-first-item (split-string (oref value msg) "\n"))))
        `((reference-link . ,reference-link)
          (author . ,(oref value author))
          (title . ,title)
          (body . ,(oref value msg)))))))

(cl-defmethod code-review-binary-file-url ((github code-review-github-repo) filename &optional blob?)
  "Make the GITHUB url for the FILENAME.
Return the blob URL if BLOB? is provided."
  (if blob?
      (format "https://github.com/%s/%s/blob/%s/%s"
              (oref github owner)
              (oref github repo)
              (oref github sha)
              filename)
    (format "https://%s/repos/%s/%s/contents/%s?ref=%s"
            code-review-github-host
            (oref github owner)
            (oref github repo)
            filename
            (oref github sha))))

(cl-defmethod code-review-binary-file ((github code-review-github-repo) filename)
  "Get FILENAME from GITHUB."
  (let* ((pwd (auth-source-pick-first-password :host code-review-github-host))
         (headers (format "--header 'Authorization: token %s' --header 'Accept: application/vnd.github.v3.raw'"
                          pwd))
         (url (code-review-binary-file-url github filename)))
    (code-review-utils--fetch-binary-data url filename headers)))

(cl-defmethod code-review-core-new-issue-comment ((github code-review-github-repo) comment-msg callback)
  "Create a new comment issue for GITHUB sending the COMMENT-MSG and call CALLBACK."
  (ghub-post (format "/repos/%s/%s/issues/%s/comments"
                     (oref github owner)
                     (oref github repo)
                     (oref github number))
             nil
             :auth 'code-review
             :host code-review-github-host
             :payload (a-alist 'body comment-msg)
             :callback callback
             :errorback #'code-review-github-errback))

(provide 'code-review-github)
;;; code-review-github.el ends here
