#import "GitShim.h"
#import <git2.h>

static int gExit = 0;
static dispatch_once_t gOnce;

static void ensureGit(void) {
    dispatch_once(&gOnce, ^{
        git_libgit2_init();
    });
}

static NSString *lastGitError(void) {
    const git_error *e = git_error_last();
    if (e && e->message) return [NSString stringWithUTF8String:e->message];
    return @"unknown libgit2 error";
}

static void fail(NSMutableString *out, NSString *message) {
    gExit = 1;
    [out appendFormat:@"fatal: %@\n", message];
}

static NSArray<NSString *> *splitArgs(NSString *input) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    BOOL inSingle = NO, inDouble = NO, has = NO;
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (c == '\\' && !inSingle && i + 1 < input.length) {
            [cur appendFormat:@"%C", [input characterAtIndex:++i]];
            has = YES;
            continue;
        }
        if (c == '\'' && !inDouble) { inSingle = !inSingle; has = YES; continue; }
        if (c == '"' && !inSingle) { inDouble = !inDouble; has = YES; continue; }
        if ((c == ' ' || c == '\t' || c == '\n') && !inSingle && !inDouble) {
            if (has) { [out addObject:[cur copy]]; [cur setString:@""]; has = NO; }
            continue;
        }
        [cur appendFormat:@"%C", c];
        has = YES;
    }
    if (has) [out addObject:[cur copy]];
    return out;
}

static git_repository *openRepo(NSString *cwd) {
    git_repository *repo = NULL;
    if (git_repository_open_ext(&repo, cwd.fileSystemRepresentation, 0, NULL) != 0) {
        return NULL;
    }
    return repo;
}

static NSString *headBranch(git_repository *repo) {
    git_reference *head = NULL;
    const char *name = NULL;
    NSString *result = @"HEAD";
    if (git_repository_head(&head, repo) == 0 && git_branch_name(&name, head) == 0 && name) {
        result = [NSString stringWithUTF8String:name];
    }
    if (head) git_reference_free(head);
    return result;
}

static char statusChar(unsigned int s, BOOL indexSide) {
    if (indexSide) {
        if (s & GIT_STATUS_INDEX_NEW) return 'A';
        if (s & GIT_STATUS_INDEX_MODIFIED) return 'M';
        if (s & GIT_STATUS_INDEX_DELETED) return 'D';
        if (s & GIT_STATUS_INDEX_RENAMED) return 'R';
        if (s & GIT_STATUS_INDEX_TYPECHANGE) return 'T';
    } else {
        if (s & GIT_STATUS_WT_NEW) return '?';
        if (s & GIT_STATUS_WT_MODIFIED) return 'M';
        if (s & GIT_STATUS_WT_DELETED) return 'D';
        if (s & GIT_STATUS_WT_RENAMED) return 'R';
        if (s & GIT_STATUS_WT_TYPECHANGE) return 'T';
    }
    return ' ';
}

static int diffLineCallback(const git_diff_delta *delta,
                            const git_diff_hunk *hunk,
                            const git_diff_line *line,
                            void *payload) {
    NSMutableString *out = (__bridge NSMutableString *)payload;
    if (line->origin == GIT_DIFF_LINE_FILE_HDR ||
        line->origin == GIT_DIFF_LINE_HUNK_HDR ||
        line->origin == GIT_DIFF_LINE_CONTEXT ||
        line->origin == GIT_DIFF_LINE_ADDITION ||
        line->origin == GIT_DIFF_LINE_DELETION) {
        if (line->content_len > 0) {
            NSString *s = [[NSString alloc] initWithBytes:line->content length:line->content_len encoding:NSUTF8StringEncoding];
            if (s) [out appendString:s];
        }
    }
    return 0;
}

static NSString *commitMessage(NSArray<NSString *> *args, BOOL *all) {
    NSMutableString *msg = [NSMutableString string];
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"-a"] || [a isEqualToString:@"-am"] || [a isEqualToString:@"--all"]) {
            if (all) *all = YES;
            continue;
        }
        if ([a isEqualToString:@"-m"] || [a isEqualToString:@"--message"]) {
            if (i + 1 < args.count) { [msg appendString:args[++i]]; }
            continue;
        }
        if ([a hasPrefix:@"-m"]) {
            [msg appendString:[a substringFromIndex:2]];
            continue;
        }
        if ([a hasPrefix:@"--message="]) {
            [msg appendString:[a substringFromIndex:10]];
        }
    }
    return msg;
}

BOOL OCMGitIsCommand(NSString *command) {
    NSArray *args = splitArgs(command);
    if (args.count == 0) return NO;
    return [args[0] isEqualToString:@"git"];
}

int OCMGitLastExit(void) { return gExit; }

NSString *OCMGitRun(NSString *command, NSString *cwd) {
    ensureGit();
    gExit = 0;
    NSMutableString *out = [NSMutableString string];
    NSArray<NSString *> *tokens = splitArgs(command);
    if (tokens.count == 0) return @"";
    NSUInteger idx = [tokens[0] isEqualToString:@"git"] ? 1 : 0;
    if (idx >= tokens.count) {
        [out appendString:@"usage: git <command> [<args>]\n"];
        gExit = 1;
        return out;
    }
    NSString *sub = tokens[idx++];
    NSArray<NSString *> *args = idx < tokens.count ? [tokens subarrayWithRange:NSMakeRange(idx, tokens.count - idx)] : @[];

    if ([sub isEqualToString:@"version"] || [sub isEqualToString:@"--version"]) {
        int major = 0, minor = 0, rev = 0;
        git_libgit2_version(&major, &minor, &rev);
        [out appendFormat:@"git version (libgit2 %d.%d.%d)\n", major, minor, rev];
        return out;
    }

    if ([sub isEqualToString:@"init"]) {
        NSString *path = args.count ? args[0] : cwd;
        if (![path isAbsolutePath]) path = [cwd stringByAppendingPathComponent:path];
        git_repository *repo = NULL;
        if (git_repository_init(&repo, path.fileSystemRepresentation, 0) != 0) {
            fail(out, lastGitError());
        } else {
            [out appendFormat:@"Initialized empty Git repository in %@/.git/\n", path];
            git_repository_free(repo);
        }
        return out;
    }

    git_repository *repo = openRepo(cwd);
    if (!repo) {
        fail(out, [NSString stringWithFormat:@"not a git repository (or any parent): %@", cwd]);
        return out;
    }

    if ([sub isEqualToString:@"status"]) {
        git_status_options opts = GIT_STATUS_OPTIONS_INIT;
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
        git_status_list *list = NULL;
        if (git_status_list_new(&list, repo, &opts) != 0) {
            fail(out, lastGitError());
        } else {
            size_t n = git_status_list_entrycount(list);
            BOOL shortMode = [args containsObject:@"-s"] || [args containsObject:@"--short"];
            if (n == 0) {
                [out appendFormat:@"On branch %@\nnothing to commit, working tree clean\n", headBranch(repo)];
            } else if (!shortMode) {
                [out appendFormat:@"On branch %@\n\n", headBranch(repo)];
            }
            for (size_t i = 0; i < n; i++) {
                const git_status_entry *e = git_status_byindex(list, i);
                if (!e) continue;
                NSString *path = @"";
                if (e->index_to_workdir && e->index_to_workdir->new_file.path) {
                    path = [NSString stringWithUTF8String:e->index_to_workdir->new_file.path];
                } else if (e->head_to_index && e->head_to_index->old_file.path) {
                    path = [NSString stringWithUTF8String:e->head_to_index->old_file.path];
                }
                char x = statusChar(e->status, YES);
                char y = statusChar(e->status, NO);
                if (e->status & GIT_STATUS_WT_NEW) { x = '?'; y = '?'; }
                [out appendFormat:@"%c%c %@\n", x, y, path];
            }
            git_status_list_free(list);
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"add"]) {
        git_index *index = NULL;
        if (git_repository_index(&index, repo) != 0) {
            fail(out, lastGitError());
        } else {
            BOOL all = args.count == 0 || [args containsObject:@"-A"] || [args containsObject:@"--all"] || [args containsObject:@"."];
            if (all) {
                if (git_index_add_all(index, NULL, GIT_INDEX_ADD_DEFAULT, NULL, NULL) != 0) fail(out, lastGitError());
            } else {
                for (NSString *p in args) {
                    if ([p hasPrefix:@"-"]) continue;
                    if (git_index_add_bypath(index, p.fileSystemRepresentation) != 0) {
                        fail(out, [NSString stringWithFormat:@"%@: %@", p, lastGitError()]);
                    }
                }
            }
            if (git_index_write(index) != 0) fail(out, lastGitError());
            git_index_free(index);
            if (gExit == 0 && !all) [out appendFormat:@"added %lu path(s)\n", (unsigned long)args.count];
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"reset"]) {
        git_index *index = NULL;
        if (git_repository_index(&index, repo) == 0) {
            if (git_index_read(index, 1) == 0 && git_index_write(index) == 0) {
                [out appendString:@"Unstaged changes reset\n"];
            } else {
                fail(out, lastGitError());
            }
            git_index_free(index);
        } else {
            fail(out, lastGitError());
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"commit"]) {
        BOOL addAll = NO;
        NSString *msg = commitMessage(args, &addAll);
        if (msg.length == 0) {
            fail(out, @"interactive commit is not supported on iOS; use git commit -m \"message\"");
            git_repository_free(repo);
            return out;
        }
        git_index *index = NULL;
        if (git_repository_index(&index, repo) != 0) {
            fail(out, lastGitError());
            git_repository_free(repo);
            return out;
        }
        if (addAll) {
            git_index_add_all(index, NULL, GIT_INDEX_ADD_DEFAULT, NULL, NULL);
        }
        if (git_index_write(index) != 0) {
            fail(out, lastGitError());
            git_index_free(index);
            git_repository_free(repo);
            return out;
        }
        git_oid treeOid;
        git_tree *tree = NULL;
        git_commit *parent = NULL;
        const git_commit *parents[1];
        size_t parentCount = 0;
        git_reference *headRef = NULL;
        if (git_repository_head(&headRef, repo) == 0 && headRef) {
            const git_oid *parentOid = git_reference_target(headRef);
            if (parentOid && git_commit_lookup(&parent, repo, parentOid) == 0) {
                parents[0] = parent;
                parentCount = 1;
            }
            git_reference_free(headRef);
        }
        if (git_index_write_tree(&treeOid, index) != 0 || git_tree_lookup(&tree, repo, &treeOid) != 0) {
            fail(out, lastGitError());
            if (parent) git_commit_free(parent);
            git_index_free(index);
            git_repository_free(repo);
            return out;
        }
        git_config *cfg = NULL;
        git_repository_config(&cfg, repo);
        const char *name = NULL, *email = NULL;
        if (cfg) {
            git_config_get_string(&name, cfg, "user.name");
            git_config_get_string(&email, cfg, "user.email");
        }
        git_signature *sig = NULL;
        if (git_signature_now(&sig, name ?: "OpenCode", email ?: "opencode@ios.local") != 0) {
            fail(out, lastGitError());
        } else {
            git_oid commitOid;
            int rc = git_commit_create(&commitOid, repo, "HEAD", sig, sig, NULL, msg.UTF8String,
                                       tree, parentCount, parentCount ? parents : NULL);
            if (rc != 0) {
                fail(out, lastGitError());
            } else {
                char oidstr[GIT_OID_HEXSZ + 1];
                git_oid_tostr(oidstr, sizeof(oidstr), &commitOid);
                [out appendFormat:@"[%@ %s] %@\n", headBranch(repo), oidstr, msg];
            }
            git_signature_free(sig);
        }
        if (cfg) git_config_free(cfg);
        if (parent) git_commit_free(parent);
        git_tree_free(tree);
        git_index_free(index);
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"log"]) {
        NSUInteger limit = 20;
        for (NSUInteger i = 0; i < args.count; i++) {
            if (([args[i] isEqualToString:@"-n"] || [args[i] isEqualToString:@"--max-count"]) && i + 1 < args.count) {
                limit = (NSUInteger)MAX(1, args[i + 1].integerValue);
            }
        }
        BOOL oneLine = [args containsObject:@"--oneline"];
        git_revwalk *walk = NULL;
        if (git_revwalk_new(&walk, repo) != 0 || git_revwalk_push_head(walk) != 0) {
            fail(out, lastGitError());
        } else {
            git_revwalk_sorting(walk, GIT_SORT_TIME);
            git_oid oid;
            NSUInteger shown = 0;
            while (shown < limit && git_revwalk_next(&oid, walk) == 0) {
                git_commit *c = NULL;
                if (git_commit_lookup(&c, repo, &oid) != 0) break;
                char oidstr[GIT_OID_HEXSZ + 1];
                git_oid_tostr(oidstr, sizeof(oidstr), &oid);
                const char *summary = git_commit_summary(c);
                const git_signature *author = git_commit_author(c);
                if (oneLine) {
                    [out appendFormat:@"%.7s %s\n", oidstr, summary ?: ""];
                } else {
                    [out appendFormat:@"commit %s\nAuthor: %s <%s>\n\n    %s\n\n", oidstr,
                     author && author->name ? author->name : "unknown",
                     author && author->email ? author->email : "",
                     summary ?: ""];
                }
                git_commit_free(c);
                shown++;
            }
        }
        if (walk) git_revwalk_free(walk);
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"diff"]) {
        BOOL cached = [args containsObject:@"--cached"] || [args containsObject:@"--staged"];
        git_diff *diff = NULL;
        int rc = 0;
        git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
        if (cached) {
            git_reference *head = NULL;
            git_commit *commit = NULL;
            git_tree *tree = NULL;
            if (git_repository_head(&head, repo) == 0) {
                const git_oid *oid = git_reference_target(head);
                if (oid && git_commit_lookup(&commit, repo, oid) == 0) {
                    git_commit_tree(&tree, commit);
                }
            }
            rc = git_diff_tree_to_index(&diff, repo, tree, NULL, &opts);
            if (tree) git_tree_free(tree);
            if (commit) git_commit_free(commit);
            if (head) git_reference_free(head);
        } else {
            rc = git_diff_index_to_workdir(&diff, repo, NULL, &opts);
        }
        if (rc != 0) {
            fail(out, lastGitError());
        } else if (diff) {
            git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, diffLineCallback, (__bridge void *)out);
            git_diff_free(diff);
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"branch"]) {
        git_branch_iterator *it = NULL;
        if (git_branch_iterator_new(&it, repo, GIT_BRANCH_LOCAL) != 0) {
            fail(out, lastGitError());
        } else {
            git_reference *ref = NULL;
            git_branch_t type;
            while (git_branch_next(&ref, &type, it) == 0) {
                const char *name = NULL;
                if (git_branch_name(&name, ref) == 0 && name) {
                    [out appendFormat:@"%@%s\n", git_branch_is_head(ref) ? "* " : "  ", name];
                }
                git_reference_free(ref);
            }
            git_branch_iterator_free(it);
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"checkout"] || [sub isEqualToString:@"switch"]) {
        BOOL create = [args containsObject:@"-b"] || [args containsObject:@"-c"];
        NSString *name = nil;
        for (NSString *a in args) {
            if ([a hasPrefix:@"-"]) continue;
            name = a;
            break;
        }
        if (!name) {
            fail(out, @"usage: git checkout [-b] <branch>");
            git_repository_free(repo);
            return out;
        }
        git_object *target = NULL;
        if (create) {
            git_commit *headCommit = NULL;
            git_reference *head = NULL;
            git_reference *branchRef = NULL;
            if (git_repository_head(&head, repo) == 0) {
                const git_oid *oid = git_reference_target(head);
                if (oid) git_commit_lookup(&headCommit, repo, oid);
                git_reference_free(head);
            }
            if (!headCommit || git_branch_create(&branchRef, repo, name.UTF8String, headCommit, 0) != 0) {
                fail(out, lastGitError());
                if (headCommit) git_commit_free(headCommit);
                if (branchRef) git_reference_free(branchRef);
                git_repository_free(repo);
                return out;
            }
            if (headCommit) git_commit_free(headCommit);
            if (branchRef) git_reference_free(branchRef);
        }
        if (!target) {
            NSString *refname = [NSString stringWithFormat:@"refs/heads/%@", name];
            if (git_revparse_single(&target, repo, refname.UTF8String) != 0) {
                fail(out, [NSString stringWithFormat:@"branch not found: %@", name]);
                git_repository_free(repo);
                return out;
            }
        }
        git_checkout_options copts = GIT_CHECKOUT_OPTIONS_INIT;
        copts.checkout_strategy = GIT_CHECKOUT_SAFE;
        if (git_checkout_tree(repo, target, &copts) != 0) {
            fail(out, lastGitError());
        } else {
            NSString *refname = [NSString stringWithFormat:@"refs/heads/%@", name];
            if (git_repository_set_head(repo, refname.UTF8String) != 0) fail(out, lastGitError());
            else [out appendFormat:@"Switched to branch '%@'\n", name];
        }
        if (target) git_object_free(target);
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"rev-parse"]) {
        if ([args containsObject:@"--show-toplevel"]) {
            const char *wd = git_repository_workdir(repo);
            [out appendFormat:@"%s\n", wd ? wd : ""];
        } else if ([args containsObject:@"--abbrev-ref"]) {
            [out appendFormat:@"%@\n", headBranch(repo)];
        } else {
            git_object *obj = NULL;
            if (git_revparse_single(&obj, repo, "HEAD") == 0) {
                char oidstr[GIT_OID_HEXSZ + 1];
                git_oid_tostr(oidstr, sizeof(oidstr), git_object_id(obj));
                [out appendFormat:@"%s\n", oidstr];
                git_object_free(obj);
            } else {
                fail(out, lastGitError());
            }
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"remote"]) {
        git_strarray remotes = {0};
        if (git_remote_list(&remotes, repo) != 0) {
            fail(out, lastGitError());
        } else {
            for (size_t i = 0; i < remotes.count; i++) {
                git_remote *r = NULL;
                if (git_remote_lookup(&r, repo, remotes.strings[i]) == 0) {
                    const char *url = git_remote_url(r);
                    const char *push = git_remote_pushurl(r);
                    [out appendFormat:@"%@\t%s (fetch)\n", [NSString stringWithUTF8String:remotes.strings[i]], url ?: ""];
                    [out appendFormat:@"%@\t%s (push)\n", [NSString stringWithUTF8String:remotes.strings[i]], push ?: url ?: ""];
                    git_remote_free(r);
                }
            }
            git_strarray_free(&remotes);
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"config"]) {
        if (args.count >= 2) {
            NSString *key = args[0];
            NSString *value = args[1];
            git_config *cfg = NULL;
            if (git_repository_config(&cfg, repo) == 0 &&
                git_config_set_string(cfg, key.UTF8String, value.UTF8String) == 0) {
                [out appendFormat:@"%@=%@\n", key, value];
            } else {
                fail(out, lastGitError());
            }
            if (cfg) git_config_free(cfg);
        } else if (args.count == 1) {
            git_config *cfg = NULL;
            const char *value = NULL;
            if (git_repository_config(&cfg, repo) == 0 && git_config_get_string(&value, cfg, args[0].UTF8String) == 0) {
                [out appendFormat:@"%s\n", value];
            } else {
                fail(out, [NSString stringWithFormat:@"config key not found: %@", args[0]]);
            }
            if (cfg) git_config_free(cfg);
        } else {
            [out appendString:@"usage: git config <key> [value]\n"];
            gExit = 1;
        }
        git_repository_free(repo);
        return out;
    }

    if ([sub isEqualToString:@"clone"]) {
        if (args.count == 0) {
            fail(out, @"usage: git clone <url> [dir]");
        } else {
            NSString *url = args[0];
            NSString *dest = args.count > 1 ? args[1] : [[url lastPathComponent] stringByDeletingPathExtension];
            if (![dest isAbsolutePath]) dest = [cwd stringByAppendingPathComponent:dest];
            git_repository *cloned = NULL;
            if (git_clone(&cloned, url.UTF8String, dest.fileSystemRepresentation, NULL) != 0) {
                fail(out, lastGitError());
            } else {
                [out appendFormat:@"Cloned %@ into %@\n", url, dest];
                git_repository_free(cloned);
            }
        }
        git_repository_free(repo);
        return out;
    }

    [out appendFormat:@"git: '%@' is not supported on iOS (available: init, status, add, reset, commit, log, diff, branch, checkout, rev-parse, remote, config, clone, version)\n", sub];
    gExit = 1;
    git_repository_free(repo);
    return out;
}