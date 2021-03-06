%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Write Ahead Logging (WAL)==
%%% File storage for transaction logging done by cloudi_service_queue.
%%% No disk index is maintained, but an in-memory index is kept.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2014-2016, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2014-2016 Michael Truog
%%% @version 1.5.4 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_write_ahead_logging).
-author('mjtruog [at] gmail (dot) com').

%% external interface
-export([erase/2,
         erase_retry/4,
         fetch_keys/1,
         size/1,
         size_free/1,
         store_end/3,
         store_fail/2,
         store_start/2,
         new/3,
         update/3]).

% overhead: chunk_size, chunk_size_used
-define(CHUNK_OVERHEAD, 8 + 8).
% use 64 bit offsets/sizes
-define(MAX_64BITS, 18446744073709551615).
-type non_neg_integer_64bit() :: 0..?MAX_64BITS.
-type pos_integer_64bit() :: 1..?MAX_64BITS.

-record(chunk,
    {
        size :: pos_integer_64bit(),         % bytes (wo/overhead)
        position :: non_neg_integer_64bit(), % file position (bof) in bytes
        request :: cloudi_service_queue:request() | undefined,
        retries = 0 :: non_neg_integer()
    }).

-ifdef(ERLANG_OTP_VERSION_16).
-type dict_proxy(_Key, _Value) :: dict().
-else.
-type dict_proxy(Key, Value) :: dict:dict(Key, Value).
-endif.
-record(state,
    {
        file = undefined :: undefined | string(),
        compression = undefined :: undefined | 0..9, % zlib compression level
        position = undefined :: undefined | non_neg_integer(),
        chunks = dict:new() :: dict_proxy(cloudi_service:trans_id(), #chunk{}),
        chunks_free = [] :: list(#chunk{}) % ordered
    }).

-type state() :: #state{}.
-type retry_function() ::
    fun((Chunk :: cloudi_service_queue:request(),
         Retry :: boolean()) ->
        {ok, cloudi_service:trans_id()} |
        {error, timeout}).
-type update_function() ::
    fun((cloudi_service_queue:request()) ->
        {cloudi_service:trans_id(),
         cloudi_service_queue:request()} | undefined).
-export_type([state/0,
              retry_function/0,
              update_function/0]).

-define(FILE_EXTENSION_TMP, ".tmp").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

-spec erase(ChunkId :: cloudi_service:trans_id(),
            State :: #state{}) ->
    {cloudi_service_queue:request(), #state{}}.

erase(ChunkId,
      #state{file = FilePath,
             chunks = Chunks} = State) ->
    Chunk = dict:fetch(ChunkId, Chunks),
    #chunk{request = ChunkRequest} = Chunk,
    {ok, Fd} = file_open_tmp(FilePath),
    NewState = erase_chunk(Chunk, Fd, State),
    ok = file_close_tmp(FilePath, Fd),
    {ChunkRequest, NewState#state{chunks = dict:erase(ChunkId, Chunks)}}.

-spec erase_retry(ChunkId :: cloudi_service:trans_id(),
                  RetryMax :: non_neg_integer(),
                  RetryF :: retry_function(),
                  State :: #state{}) ->
    #state{}.

erase_retry(ChunkId, RetryMax, RetryF,
            #state{file = FilePath,
                   chunks = Chunks} = State) ->
    Chunk = dict:fetch(ChunkId, Chunks),
    #chunk{request = ChunkRequest,
           retries = Retries} = Chunk,
    NewChunkId = case RetryF(ChunkRequest, Retries < RetryMax) of
        {error, timeout} ->
            undefined;
        {ok, TransId} ->
            TransId
    end,
    if
        NewChunkId =:= undefined ->
            {ok, Fd} = file_open_tmp(FilePath),
            NewState = erase_chunk(Chunk, Fd, State),
            ok = file_close_tmp(FilePath, Fd),
            NewState#state{chunks = dict:erase(ChunkId, Chunks)};
        is_binary(NewChunkId) ->
            NewChunk = Chunk#chunk{retries = Retries + 1},
            NewChunks = dict:erase(ChunkId, Chunks),
            State#state{chunks = dict:store(NewChunkId, NewChunk, NewChunks)}
    end.

-spec fetch_keys(State :: #state{}) ->
    list(cloudi_service:trans_id()).

fetch_keys(#state{chunks = Chunks}) ->
    lists:sort(dict:fetch_keys(Chunks)). % oldest -> newest

-spec size(State :: #state{}) ->
    non_neg_integer().

size(#state{chunks = Chunks}) ->
    dict:size(Chunks).

-spec size_free(State :: #state{}) ->
    non_neg_integer().

size_free(#state{chunks_free = ChunksFree}) ->
    erlang:length(ChunksFree).

-spec store_end(ChunkId :: cloudi_service:trans_id(),
                Chunk :: #chunk{},
                State :: #state{}) ->
    #state{}.

store_end(ChunkId, Chunk,
          #state{chunks = Chunks} = State) ->
    State#state{chunks = dict:store(ChunkId, Chunk, Chunks)}.

-spec store_fail(Chunk :: #chunk{},
                 State :: #state{}) ->
    #state{}.

store_fail(Chunk, #state{file = FilePath} = State) ->
    {ok, Fd} = file_open_tmp(FilePath),
    NewState = erase_chunk(Chunk, Fd, State),
    ok = file_close_tmp(FilePath, Fd),
    NewState.

-spec store_start(ChunkRequest :: cloudi_service_queue:request(),
                  State :: #state{}) ->
    {#chunk{}, #state{}}.

store_start(ChunkRequest,
            #state{file = FilePath,
                   compression = Compression,
                   position = Position,
                   chunks_free = ChunksFree} = State) ->
    {ok, Fd} = file_open_tmp(FilePath),
    ChunkData = erlang:term_to_binary(ChunkRequest,
                                      [{compressed, Compression}]),
    ChunkSizeUsed = erlang:byte_size(ChunkData),
    case chunk_free_check(ChunksFree, ChunkSizeUsed) of
        false ->
            ChunkSize = ChunkSizeUsed,
            NewPosition = chunk_write(ChunkSize, ChunkSizeUsed,
                                      ChunkData, Position, Fd),
            ok = file_close_tmp(FilePath, Fd),
            NewChunk = #chunk{size = ChunkSize,
                              position = Position,
                              request = ChunkRequest},
            {NewChunk, State#state{position = NewPosition}};
        {#chunk{size = ChunkSize,
                position = ChunkPosition} = ChunkFree, NewChunksFree} ->
            chunk_write(ChunkSize, ChunkSizeUsed,
                        ChunkData, ChunkPosition, Fd),
            ok = file_close_tmp(FilePath, Fd),
            NewChunk = ChunkFree#chunk{request = ChunkRequest},
            {NewChunk, State#state{chunks_free = NewChunksFree}}
    end.

-spec new(FilePath :: string(),
          Compression :: 0..9,
          RetryF :: retry_function()) ->
    #state{}.

new(FilePath, Compression, RetryF)
    when is_integer(Compression), Compression >= 0, Compression =< 9,
         is_function(RetryF, 2) ->
    State = #state{},
    #state{chunks = Chunks,
           chunks_free = ChunksFree} = State,
    {ok, Fd} = file_open_copy(FilePath),
    {ok,
     Position,
     NewChunks,
     NewChunksFree} = chunks_recover(Chunks, ChunksFree, Fd, RetryF),
    ok = file_close_tmp(FilePath, Fd),
    State#state{file = FilePath,
                compression = Compression,
                position = Position,
                chunks = NewChunks,
                chunks_free = NewChunksFree}.

-spec update(ChunkId :: cloudi_service:trans_id(),
             UpdateF :: update_function(),
             State :: #state{}) ->
    {cloudi_service_queue:request() | undefined, #state{}}.

update(ChunkId, UpdateF,
       #state{file = FilePath,
              compression = Compression,
              position = Position,
              chunks = Chunks,
              chunks_free = ChunksFree} = State) ->
    Chunk = dict:fetch(ChunkId, Chunks),
    #chunk{request = ChunkRequest} = Chunk,
    case UpdateF(ChunkRequest) of
        undefined ->
            {_, NewState} = erase(ChunkId, State),
            {undefined, NewState};
        {NewChunkId, NewChunkRequest} ->
            {ok, Fd} = file_open_tmp(FilePath),
            % store update
            NewChunkData = erlang:term_to_binary(NewChunkRequest,
                                                 [{compressed, Compression}]),
            NewChunkSizeUsed = erlang:byte_size(NewChunkData),
            NextState = case chunk_free_check(ChunksFree, NewChunkSizeUsed) of
                false ->
                    NewChunkSize = NewChunkSizeUsed,
                    NewPosition = chunk_write(NewChunkSize, NewChunkSizeUsed,
                                              NewChunkData, Position, Fd),
                    NewChunk = #chunk{size = NewChunkSize,
                                      position = Position,
                                      request = NewChunkRequest},
                    NewChunks = dict:store(NewChunkId, NewChunk, Chunks),
                    State#state{chunks = NewChunks,
                                position = NewPosition};
                {#chunk{size = ChunkSize,
                        position = ChunkPosition} = ChunkFree, NewChunksFree} ->
                    chunk_write(ChunkSize, NewChunkSizeUsed,
                                NewChunkData, ChunkPosition, Fd),
                    NewChunk = ChunkFree#chunk{request = NewChunkRequest},
                    NewChunks = dict:store(NewChunkId, NewChunk, Chunks),
                    State#state{chunks = NewChunks,
                                chunks_free = NewChunksFree}
            end,
            % erase previous entry
            NewState = erase_chunk(Chunk, Fd, NextState),
            ok = file_close_tmp(FilePath, Fd),
            {NewChunkRequest, NewState}
    end.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

file_open_copy(FilePath) ->
    case file:copy({FilePath, [raw]},
                   {FilePath ++ ?FILE_EXTENSION_TMP, [raw]}) of
        {ok, _} ->
            ok;
        {error, enoent} ->
            case file:delete(FilePath ++ ?FILE_EXTENSION_TMP) of
                ok ->
                    ok;
                {error, enoent} ->
                    ok
            end
    end,
    file:open(FilePath ++ ?FILE_EXTENSION_TMP, [raw, write, read, binary]).

file_open_tmp(FilePath) ->
    file:open(FilePath ++ ?FILE_EXTENSION_TMP, [raw, write, read, binary]).

file_close_tmp(FilePath, Fd) ->
    ok = file:close(Fd),
    ok = file:rename(FilePath ++ ?FILE_EXTENSION_TMP, FilePath),
    {ok, _} = file:copy({FilePath, [raw]},
                        {FilePath ++ ?FILE_EXTENSION_TMP, [raw]}),
    ok.

chunk_write(ChunkSize, ChunkSizeUsed, ChunkData, Position, Fd) ->
    ChunkSizeZero = (ChunkSize - ChunkSizeUsed),
    {ok, _} = file:position(Fd, Position),
    ok = file:write(Fd, <<ChunkSize:64/unsigned-integer-big,
                          ChunkSizeUsed:64/unsigned-integer-big,
                          ChunkData/binary,
                          0:(ChunkSizeZero * 8)>>),
    Position + ?CHUNK_OVERHEAD + ChunkSize.

chunk_erase_last(ChunkSize, Position, Fd) ->
    {ok, _} = file:position(Fd, Position),
    ok = file:write(Fd, <<0:64,
                          0:64,
                          0:(ChunkSize * 8)>>),
    ok.

chunk_free(ChunkSize, Position, Fd) ->
    {ok, _} = file:position(Fd, Position),
    ok = file:write(Fd, <<ChunkSize:64/unsigned-integer-big,
                          0:64,
                          0:(ChunkSize * 8)>>),
    ok.

erase_chunk(#chunk{size = ChunkSize,
                   position = ChunkPosition} = Chunk,
            Fd,
            #state{position = Position,
                   chunks_free = ChunksFree} = State) ->
    if
        (ChunkPosition + ?CHUNK_OVERHEAD + ChunkSize) == Position ->
            chunk_erase_last(ChunkSize, ChunkPosition, Fd),
            State#state{position = ChunkPosition};
        true ->
            chunk_free(ChunkSize, ChunkPosition, Fd),
            ChunkFree = Chunk#chunk{request = undefined,
                                    retries = 0},
            State#state{chunks_free = lists:umerge(ChunksFree, [ChunkFree])}
    end.

chunk_free_check(L, Size) ->
    chunk_free_check(L, [], Size).

chunk_free_check([], _, _) ->
    false;
chunk_free_check([#chunk{size = ChunkSize} = Chunk | ChunksFree], L, Size)
    when ChunkSize >= Size ->
    {Chunk, lists:reverse(L) ++ ChunksFree};
chunk_free_check([Chunk | ChunksFree], L, Size) ->
    chunk_free_check(ChunksFree, [Chunk | L], Size).

chunk_recover_free(Position, ChunkSize, Chunks, ChunksFree, Fd, RetryF) ->
    NewPosition = Position + ?CHUNK_OVERHEAD + ChunkSize,
    ChunkFree = #chunk{size = ChunkSize,
                       position = Position,
                       request = undefined},
    chunks_recover(NewPosition, Chunks,
                   lists:umerge(ChunksFree, [ChunkFree]),
                   Fd, RetryF).

chunk_recover_used(Position, ChunkSize, ChunkSizeUsed,
                   Chunks, ChunksFree, Fd, RetryF) ->
    case file:read(Fd, ChunkSizeUsed) of
        {ok, ChunkData} ->
            ChunkRequest = erlang:binary_to_term(ChunkData),
            case RetryF(ChunkRequest, true) of
                {error, timeout} ->
                    ok = chunk_free(ChunkSize, Position, Fd),
                    chunk_recover_free(Position, ChunkSize,
                                       Chunks, ChunksFree, Fd, RetryF);
                {ok, ChunkId} when ChunkSize == ChunkSizeUsed ->
                    NewPosition = Position + ?CHUNK_OVERHEAD + ChunkSize,
                    Chunk = #chunk{size = ChunkSize,
                                   position = Position,
                                   request = ChunkRequest},
                    chunks_recover(NewPosition,
                                   dict:store(ChunkId, Chunk, Chunks),
                                   ChunksFree, Fd, RetryF);
                {ok, ChunkId} ->
                    ChunkEnd = (ChunkSize - ChunkSizeUsed),
                    case file:position(Fd, {cur, ChunkEnd}) of
                        {ok, NewPosition} ->
                            Chunk = #chunk{size = ChunkSize,
                                           position = Position,
                                           request = ChunkRequest},
                            chunks_recover(NewPosition,
                                           dict:store(ChunkId, Chunk, Chunks),
                                           ChunksFree, Fd, RetryF);
                        {error, Reason} ->
                            {error, {chunk_corrupt, Reason}}
                    end
            end;
        {error, Reason} ->
            {error, {chunk_size_used_invalid, Reason}}
    end.

chunk_recover(Position, ChunkSize, Chunks, ChunksFree, Fd, RetryF) ->
    case file:read(Fd, 8) of
        {error, Reason} ->
            {error, {chunk_used_size_invalid, Reason}};
        eof ->
            {error, {chunk_used_size_missing, eof}};
        {ok, <<0:64>>} ->
            case file:position(Fd, {cur, ChunkSize}) of
                {ok, _} ->
                    chunk_recover_free(Position, ChunkSize,
                                       Chunks, ChunksFree, Fd, RetryF);
                {error, Reason} ->
                    {error, {chunk_corrupt, Reason}}
            end;
        {ok, <<ChunkSizeUsed:64/unsigned-integer-big>>} ->
            true = (ChunkSize >= ChunkSizeUsed),
            chunk_recover_used(Position, ChunkSize, ChunkSizeUsed,
                               Chunks, ChunksFree, Fd, RetryF)
    end.

chunks_recover(Chunks, ChunksFree, Fd, RetryF) ->
    chunks_recover(0, Chunks, ChunksFree, Fd, RetryF).

chunks_recover(Position, Chunks, ChunksFree, Fd, RetryF) ->
    case file:read(Fd, 8) of
        {error, Reason} ->
            {error, {chunk_size_missing, Reason}};
        eof ->
            {ok, Position, Chunks, ChunksFree};
        {ok, <<0:64>>} ->
            {ok, Position, Chunks, ChunksFree};
        {ok, <<ChunkSize:64/unsigned-integer-big>>} ->
            chunk_recover(Position, ChunkSize,
                          Chunks, ChunksFree, Fd, RetryF)
    end.

