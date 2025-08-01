#' Capture chat model response with proper handling
#' @param original_chat Original chat model object
#' @param prompt Prompt text
#' @param type Type specification for structured data
#' @return List containing response (chat, text, and structured data)
#' @keywords internal
#' @noRd
capture <- function(original_chat,
                    prompt,
                    type,
                    echo,
                    ...) {
  chat_response <- NULL
  structured_data <- NULL
  chat <- original_chat$clone()

  args <- as.list(prompt)

  chats_obj <- withCallingHandlers(
    {
      if (!is.null(type)) {
        structured_data <- do.call(
          chat$chat_structured,
          c(args, list(type = type), list(...))
        )

        if (is.null(structured_data)) {
          stop("Received NULL structured data extraction")
        }
      } else {
        chat_response <- do.call(
          chat$chat,
          c(args, list(echo = echo), list(...))
        )

        if (is.null(chat_response)) {
          stop("Received NULL chat response")
        }
      }

      list(
        chat = chat,
        text = chat_response,
        structured_data = structured_data
      )
    },
    interrupt = function(e) {
      signalCondition(e)
    }
  )

  return(chats_obj)
}

#' Process lot of prompts with progress tracking
#' @param chat_obj Chat model object
#' @param prompts List of prompts
#' @param type Type specification for structured data
#' @param file Path to save state file (.rds)
#' @param progress Whether to show progress bars
#' @param beep Play sound on completion
#' @return Process results object
#' @keywords internal
#' @noRd
process_sequential <- function(
    chat_obj,
    prompts,
    type,
    file,
    progress,
    beep,
    echo,
    ...) {
  if (file.exists(file)) {
    chats_obj <- readRDS(file)
    if (!identical(as.list(prompts), chats_obj@prompts)) {
      cli::cli_alert_warning("Prompts don't match file. Starting fresh.")
      unlink(file)
      chats_obj <- NULL
    }
  } else {
    chats_obj <- NULL
  }

  if (is.null(chats_obj)) {
    orig_type <- if (is.atomic(prompts) && !is.list(prompts)) "vector" else "list"
    chats_obj <- process(
      prompts = as.list(prompts),
      responses = vector("list", length(prompts)),
      completed = 0L,
      file = file,
      type = type,
      progress = progress,
      input_type = orig_type,
      chunk_size = NULL,
      workers = NULL,
      state = NULL
    )
    saveRDS(chats_obj, file)
  }

  total_prompts <- length(prompts)

  if (chats_obj@completed >= total_prompts) {
    if (progress) {
      cli::cli_alert_success("Complete")
    }
    return(finish_chats_obj(chats_obj))
  }

  pb <- NULL
  if (progress) {
    pb <- cli::cli_progress_bar(
      format = paste0(
        "{cli::pb_spin} Processing chats [{cli::pb_current}/{cli::pb_total}] ",
        "[{cli::pb_bar}] {cli::pb_eta}"
      ),
      total = total_prompts
    )
    cli::cli_progress_update(id = pb, set = chats_obj@completed)
  }

  tryCatch({
    for (i in (chats_obj@completed + 1L):total_prompts) {
      response <- capture(
        chat_obj, prompts[[i]], type,
        echo = echo,
        ...
      )

      chats_obj@responses[[i]] <- response
      chats_obj@completed <- i
      saveRDS(chats_obj, file)

      if (!is.null(pb)) {
        cli::cli_progress_update(id = pb, set = i)
      }
    }

    finish_process(pb, beep, progress)
  }, error = function(e) {
    if (!is.null(pb)) {
      cli::cli_progress_done(id = pb)
    }

    saveRDS(chats_obj, file)

    if (inherits(e, "interrupt")) {
      handle_interrupt(chats_obj, beep)
    } else {
      if (beep) beepr::beep("wilhelm")
      stop(e)
    }
  }, interrupt = function(e) {
    if (!is.null(pb)) {
      cli::cli_progress_done(id = pb)
    }

    saveRDS(chats_obj, file)

    if (beep) beepr::beep("coin")
    cli::cli_alert_warning(sprintf(
      "Interrupted at chat %d of %d",
      chats_obj@completed, total_prompts
    ))
  }, finally = {
    if (!exists("chats_obj")) {
      chats_obj <- readRDS(file)
    }
  })

  finish_chats_obj(chats_obj)
}

#' Process prompts in parallel chunks with error handling and state management
#' @param chat_obj Chat model object for API calls
#' @param prompts Vector or list of prompts to process
#' @param type Optional type specification for structured data extraction
#' @param file Path to save intermediate state
#' @param workers Number of parallel workers
#' @param chunk_size Number of prompts to process in parallel at a time
#' @param beep Play sound on completion/error
#' @param max_chunk_tries Maximum tries per failed chunk
#' @param progress Whether to show progress bars
#' @return Process results object
#' @keywords internal
#' @noRd
process_future <- function(
    chat_obj,
    prompts,
    type,
    file,
    workers,
    chunk_size,
    max_chunk_tries,
    beep,
    progress,
    echo,
    ...) {
  validate_chunk <- function(chunk_chats_obj, chunk_idx) {
    if (inherits(chunk_chats_obj, "error") || inherits(chunk_chats_obj, "worker_error")) {
      return(list(valid = FALSE, message = conditionMessage(chunk_chats_obj)))
    }

    if (!is.list(chunk_chats_obj) || !("responses" %in% names(chunk_chats_obj))) {
      return(list(valid = FALSE, message = sprintf("Invalid chunk structure in chunk %d", chunk_idx)))
    }

    if (length(chunk_chats_obj$responses) == 0) {
      return(list(valid = FALSE, message = sprintf("Empty responses in chunk %d", chunk_idx)))
    }

    null_indices <- which(vapply(chunk_chats_obj$responses, is.null, logical(1)))
    if (length(null_indices) > 0) {
      return(list(
        valid = FALSE,
        message = sprintf(
          "NULL responses at indices %s in chunk %d",
          paste(null_indices, collapse = ", "), chunk_idx
        )
      ))
    }

    list(valid = TRUE, message = NULL)
  }

  total_prompts <- length(prompts)
  prompts_list <- as.list(prompts)
  original_type <- if (is.atomic(prompts) && !is.list(prompts)) "vector" else "list"

  if (file.exists(file)) {
    chats_obj <- readRDS(file)
    if (!identical(prompts_list, chats_obj@prompts)) {
      cli::cli_alert_warning("Prompts don't match file. Starting fresh.")
      unlink(file)
      chats_obj <- NULL
    }
  } else {
    chats_obj <- NULL
  }

  if (is.null(chats_obj)) {
    chats_obj <- process(
      prompts = prompts_list,
      responses = vector("list", total_prompts),
      completed = 0L,
      file = file,
      type = type,
      progress = progress,
      input_type = original_type,
      chunk_size = as.integer(chunk_size),
      workers = as.integer(workers),
      state = list(
        active_workers = 0L,
        failed_chunks = list(),
        retry_count = 0L
      )
    )
    saveRDS(chats_obj, file)
  }

  if (chats_obj@completed >= total_prompts) {
    if (progress) {
      cli::cli_alert_success("Complete")
    }
    return(finish_chats_obj(chats_obj))
  }

  future::plan(future::multisession, workers = workers)

  remaining_prompts <- prompts[(chats_obj@completed + 1L):total_prompts]
  chunks <- split(remaining_prompts, ceiling(seq_along(remaining_prompts) / chunk_size))

  pb <- NULL
  if (progress) {
    pb <- cli::cli_progress_bar(
      format = "Processing chats [{cli::pb_current}/{cli::pb_total}] [{cli::pb_bar}] {cli::pb_eta}",
      total = total_prompts
    )
    cli::cli_progress_update(id = pb, set = chats_obj@completed)
  }

  capture_future <- capture

  tryCatch({
    for (chunk_idx in seq_along(chunks)) {
      chunk <- chunks[[chunk_idx]]
      retry_count <- 0
      success <- FALSE
      last_error <- NULL

      while (!success && retry_count < max_chunk_tries) {
        retry_count <- retry_count + 1

        tool_globals <- list()
        if (is.environment(chat_obj) && exists("deferred_tools", envir = chat_obj) && length(chat_obj$deferred_tools) > 0) {
          for (tool_with_data in chat_obj$deferred_tools) {
            if ("globals" %in% names(tool_with_data) && length(tool_with_data$globals) > 0) {
              tool_globals <- c(tool_globals, tool_with_data$globals)
            }
          }
        }

        if (is.environment(chat_obj) && exists("chat_model_name", envir = chat_obj)) {
          worker_chat <- if (is.character(chat_obj$chat_model_name)) {
            constructed_chat <- do.call(ellmer::chat, c(list(chat_obj$chat_model_name), chat_obj$chat_model_args))

            if (exists("deferred_tools", envir = chat_obj) && length(chat_obj$deferred_tools) > 0) {
              for (tool_with_data in chat_obj$deferred_tools) {
                tool <- tool_with_data$tool
                constructed_chat$register_tool(tool)
              }
            }

            constructed_chat
          } else {
            stop("Invalid deferred chat construction")
          }
        } else {
          worker_chat <- chat_obj$clone()
        }

        chunk_chats_obj <-
          withCallingHandlers(
            tryCatch(
              {
                responses <- NULL
                tryCatch(
                  {
                    responses <- furrr::future_map(
                      chunk,
                      function(prompt) {
                        if (is.environment(chat_obj) && exists("chat_model_name", envir = chat_obj)) {
                          worker_chat_inner <- if (is.character(chat_obj$chat_model_name)) {
                            constructed_chat <- do.call(ellmer::chat, c(list(chat_obj$chat_model_name), chat_obj$chat_model_args))

                            if (exists("deferred_tools", envir = chat_obj) && length(chat_obj$deferred_tools) > 0) {
                              for (tool_with_data in chat_obj$deferred_tools) {
                                tool <- tool_with_data$tool
                                constructed_chat$register_tool(tool)
                              }
                            }

                            constructed_chat
                          } else {
                            stop("Invalid deferred chat construction")
                          }
                        } else {
                          worker_chat_inner <- worker_chat
                        }

                        capture_future(
                          worker_chat_inner,
                          prompt,
                          type,
                          echo = echo,
                          ...
                        )
                      },
                      .options = furrr::furrr_options(
                        scheduling = 1,
                        seed = TRUE,
                        globals = c(list(chat_obj = chat_obj, type = type, echo = echo, capture_future = capture_future), tool_globals)
                      )
                    )

                    list(
                      success = TRUE,
                      responses = responses
                    )
                  },
                  error = function(e) {
                    error_msg <- conditionMessage(e)
                    if (grepl("Caused by error", error_msg)) {
                      error_msg <- gsub(".*\\!\\s*", "", error_msg)
                    }

                    stop(error_msg, call. = FALSE)
                  }
                )
              },
              error = function(e) {
                last_error <- e
                stop(conditionMessage(e),
                  call. = FALSE, domain = "process_future"
                )
                e_class <- class(e)[1]
                cli::cli_alert_warning(sprintf(
                  "Error in chunk processing (%s): %s",
                  e_class, conditionMessage(e)
                ))
                structure(
                  list(
                    success = FALSE,
                    error = "other",
                    message = conditionMessage(e)
                  ),
                  class = c("worker_error", "error")
                )
              }
            )
          )

        validation <- validate_chunk(chunk_chats_obj, chunk_idx)
        success <- validation$valid

        if (success) {
          start_idx <- chats_obj@completed + 1
          end_idx <- chats_obj@completed + length(chunk)

          chats_obj@responses[start_idx:end_idx] <- chunk_chats_obj$responses

          chats_obj@completed <- end_idx
          saveRDS(chats_obj, file)
          if (!is.null(pb)) {
            cli::cli_progress_update(id = pb, set = chats_obj@completed)
          }
        } else {
          success <- FALSE
          break
        }
      }

      if (!success) {
        error_msg <- if (!is.null(last_error)) {
          sprintf(
            "Chunk %d failed after %d attempts. Last error: %s",
            chunk_idx, max_chunk_tries, conditionMessage(last_error)
          )
        } else {
          sprintf(
            "Chunk %d failed after %d attempts: %s",
            chunk_idx, max_chunk_tries, validation$message
          )
        }
        stop(error_msg)
      }
    }

    finish_process(pb, beep, progress)
  }, error = function(e) {
    if (!is.null(pb)) {
      cli::cli_progress_done(id = pb)
    }
    saveRDS(chats_obj, file)

    if (inherits(e, "interrupt")) {
      handle_interrupt(chats_obj, beep)
    } else {
      if (beep) beepr::beep("wilhelm")
      stop(e)
    }
  }, interrupt = function(e) {
    if (!is.null(pb)) {
      cli::cli_progress_done(id = pb)
    }
    saveRDS(chats_obj, file)

    if (beep) beepr::beep("coin")
    cli::cli_alert_warning(sprintf(
      "Interrupted at chat %d of %d",
      chats_obj@completed, total_prompts
    ))
  }, finally = {
    if (!exists("chats_obj")) {
      chats_obj <- readRDS(file)
    }
    future::plan(future::sequential)
  })

  finish_chats_obj(chats_obj)
}

#' Process chunks of prompts in parallel
#' @param chunks List of prompt chunks to process
#' @param chats_obj A process object to store results
#' @param chat_obj Chat model object for making API calls
#' @param type Type specification for structured data extraction
#' @param pb Progress bar object
#' @param file Path to save intermediate state
#' @param progress Whether to show progress bars
#' @param beep Logical indicating whether to play sounds
#' @return Updated process object with processed results
#' @keywords internal
#' @noRd
process_chunks <- function(chunks,
                           chats_obj,
                           chat_obj,
                           type,
                           pb,
                           file,
                           progress,
                           beep,
                           echo,
                           ...) {
  was_interrupted <- FALSE
  capture_future <- capture

  for (chunk in chunks) {
    if (was_interrupted) break

    withCallingHandlers(
      {
        new_responses <- furrr::future_map(
          chunk,
          function(prompt) {
            if (is.environment(chat_obj) && exists("chat_model_name", envir = chat_obj)) {
              worker_chat <- if (is.character(chat_obj$chat_model_name)) {
                do.call(ellmer::chat, c(list(chat_obj$chat_model_name), chat_obj$chat_model_args))
              } else {
                stop("Invalid deferred chat construction")
              }
            } else {
              worker_chat <- chat_obj$clone()
            }

            capture_future(
              worker_chat,
              prompt,
              type,
              echo = echo,
              ...
            )
          },
          .progress = FALSE
        )

        start_idx <- chats_obj@completed + 1
        end_idx <- chats_obj@completed + length(new_responses)
        chats_obj@responses[start_idx:end_idx] <- new_responses
        chats_obj@completed <- end_idx
        saveRDS(chats_obj, file)
        if (!is.null(pb)) {
          cli::cli_progress_update(id = pb, set = end_idx)
        }
      },
      interrupt = function(e) {
        was_interrupted <<- TRUE
        handle_interrupt(chats_obj, beep)
        invokeRestart("abort")
      }
    )
  }

  if (!was_interrupted) {
    finish_process(pb, beep, progress)
  }
}


#' Handle interruption
#' @name handle_interrupt
#' @usage handle_interrupt(chats_obj, beep)
#' @param chats_obj A process object containing processing state
#' @param beep Logical indicating whether to play a sound
#' @return NULL (called for side effects)
#' @keywords internal
#' @noRd
handle_interrupt <- function(chats_obj, beep) {
  cli::cli_alert_warning(
    sprintf(
      "Interrupted at chat %d of %d",
      chats_obj@completed, length(chats_obj@prompts)
    )
  )
  if (beep) beepr::beep("coin")
}

#' Finish successful processing
#' @description Called after successful completion of processing to update progress
#'   indicators and play a success sound
#' @param pb Progress bar object
#' @param beep Logical; whether to play success sound
#' @param progress Whether to show progress bars
#' @return NULL (invisibly)
#' @keywords internal
#' @noRd
finish_process <- function(pb, beep, progress) {
  if (!is.null(pb)) {
    cli::cli_progress_done(id = pb)
  }
  if (progress) {
    cli::cli_alert_success("Complete")
  }
  if (beep) beepr::beep("ping")
  invisible()
}

#' Finish chats object by converting it to a list and assigning functions
#' @param chats_obj Process object
#' @return List with class "process"
#' @keywords internal
#' @noRd
finish_chats_obj <- function(chats_obj) {
  chats_list <- list(
    prompts = chats_obj@prompts,
    responses = chats_obj@responses,
    completed = chats_obj@completed,
    file = chats_obj@file,
    type = chats_obj@type
  )

  chats_list$texts <- function() texts(chats_obj)
  chats_list$chats <- function() chats(chats_obj)
  chats_list$progress <- function() progress(chats_obj)

  structure(chats_list, class = "process")
}
