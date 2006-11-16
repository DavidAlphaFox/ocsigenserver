(* Ocsigen
 * http://www.ocsigen.org
 * Module server.ml
 * Copyright (C) 2005 Vincent Balat, Denis Berthod, Nataliya Guts
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

open Lwt
open Messages
open Ocsimisc
open Pagesearch
open Ocsigen
open Http_frame
open Http_com
open Sender_helpers
open Ocsiconfig
open Parseconfig
open Error_pages

exception Ocsigen_unsupported_media
exception Ssl_Exception
exception Ocsigen_upload_forbidden

(* Without the following line, it stops with "Broken Pipe" without raising
   an exception ... *)
let _ = Sys.set_signal Sys.sigpipe Sys.Signal_ignore


(* non blocking input and output (for use with lwt): *)

(* let _ = Unix.set_nonblock Unix.stdin
let _ = Unix.set_nonblock Unix.stdout
let _ = Unix.set_nonblock Unix.stderr *)


let new_socket () = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0
let local_addr num = Unix.ADDR_INET (Unix.inet_addr_any, num)
    
let _ = Ssl.init ()
let sslctx = ref (Ssl.create_context Ssl.SSLv23 Ssl.Server_context)


let ip_of_sockaddr = function
    Unix.ADDR_INET (ip,port) -> Unix.string_of_inet_addr ip
  | _ -> "127.0.0.1"

let server_name = ("Ocsigen server ("^Ocsiconfig.version_number^")")

(* Ces deux trucs sont dans Neturl version 1.1.2 mais en attendant qu'ils
 soient dans debian, je les mets ici *)
let problem_re = Pcre.regexp "[ <>\"{}|\\\\^\\[\\]`]"

let fixup_url_string =
  Netstring_pcre.global_substitute
    problem_re
    (fun m s ->
       Printf.sprintf "%%%02x" 
        (Char.code s.[Netstring_pcre.match_beginning m]))
;;

let get_boundary cont_enc =
  let (_,res) = Netstring_pcre.search_forward
      (Netstring_pcre.regexp "boundary=([^;]*);?") cont_enc 0 in
  Netstring_pcre.matched_group res 1 cont_enc

let find_field field content_disp = 
  let (_,res) = Netstring_pcre.search_forward
      (Netstring_pcre.regexp (field^"=.([^\"]*).;?")) content_disp 0 in
  Netstring_pcre.matched_group res 1 content_disp

type to_write = No_File of string * Buffer.t | A_File of Lwt_unix.descr

let now = return ()





(* Errors during requests *)
let handle_light_request_errors 
    xhtml_sender sockaddr wait_end_request waiter exn = 
  (* EXCEPTIONS ABOUT THE REQUEST *)
  (* It can be an error during get_http_frame or during get_frame_info *)

  Messages.debug ("~~~~ Exception request: "^(Printexc.to_string exn));
  let ip = ip_of_sockaddr sockaddr in
  waiter >>= (fun () ->
    match exn with
      
      (* First light errors: we answer, then we wait the following request *)
      (* For now: none *)
      (* If the request has not been fully read, it must have been consumed *)
      (* Do not forget to wake up wait_end_request after having read all
       the resquest *)
      (* Find the value of keep-alive in the request *)
      
      (* Request errors: we answer, then we close *)
      Http_error.Http_exception (_,_) ->
        send_error now
          ~keep_alive:false ~http_exception:exn xhtml_sender >>=
        (fun _ -> fail (Ocsigen_Request_interrupted exn))
    | Ocsigen_header_too_long ->
        Messages.debug "Sending 400";
        (* 414 URI too long. Actually, it is "header too long..." *)
        send_error now ~keep_alive:false ~error_num:400 xhtml_sender >>= 
        (fun _ -> fail (Ocsigen_Request_interrupted exn))
    | Ocsigen_Request_too_long ->
        Messages.debug "Sending 400";
        send_error now ~keep_alive:false ~error_num:400 xhtml_sender >>= 
        (fun _ -> fail (Ocsigen_Request_interrupted exn))
    | Ocsigen_Bad_Request ->
        Messages.debug "Sending 400";
        send_error now ~keep_alive:false ~error_num:400 xhtml_sender >>= 
        (fun _ -> fail (Ocsigen_Request_interrupted exn))
    | Ocsigen_upload_forbidden ->
        Messages.debug "Sending 403 Forbidden";
        send_error now ~keep_alive:false ~error_num:400 xhtml_sender >>= 
        (fun _ -> fail (Ocsigen_Request_interrupted exn))
    | Ocsigen_unsupported_media ->
        Messages.debug "Sending 415";
        send_error now ~keep_alive:false ~error_num:415 xhtml_sender >>= 
        (fun _ -> fail (Ocsigen_Request_interrupted exn))

    (* Now errors that close the socket: we raise the exception again: *)
    | Ocsigen_HTTP_parsing_error (s1,s2) as e ->
        warning ("While talking to "^ip^": HTTP parsing error near ("^s1^
                ") in:\n"^
                (if (String.length s2)>2000 
                then ((String.sub s2 0 1999)^"...<truncated>")
                else s2)^"\n---");
        fail (Ocsigen_Request_interrupted e)
    | Unix.Unix_error(Unix.ECONNRESET,_,_)
    | Ssl.Read_error Ssl.Error_zero_return
    | Ssl.Read_error Ssl.Error_syscall ->
        fail Connection_reset_by_peer
    | Ocsigen_Timeout 
    | Http_com.Ocsigen_KeepaliveTimeout
    | Connection_reset_by_peer
    | Ocsigen_Request_interrupted _ -> fail exn
    | _ -> fail (Ocsigen_Request_interrupted exn)
             )




(* reading the request *)
let get_frame_infos http_frame filenames =

  catch (fun () -> 
    let meth = Http_header.get_method http_frame.Stream_http_frame.header in
    let url = Http_header.get_url http_frame.Stream_http_frame.header in
    let url2 = 
      Neturl.parse_url 
        ~base_syntax:(Hashtbl.find Neturl.common_url_syntax "http")
        (* ~accept_8bits:true *)
        (* Neturl.fixup_url_string url *)
        (fixup_url_string url)
    in
    let path = Neturl.string_of_url
        (Neturl.remove_from_url 
           ~param:true
           ~query:true 
           ~fragment:true 
           url2) in
    let host =
      try
        let hostport = 
          Http_header.get_headers_value http_frame.Stream_http_frame.header "Host" in
            try 
          Some (String.sub hostport 0 (String.index hostport ':'))
        with _ -> Some hostport
      with _ -> None
    in
    Messages.debug ("host="^(match host with None -> "<none>" | Some h -> h));
    let params = Neturl.string_of_url
        (Neturl.remove_from_url
           ~user:true
           ~user_param:true
           ~password:true
           ~host:true
           ~port:true
           ~path:true
           ~other:true
           url2) in
    let params_string = try
      Neturl.url_query ~encoded:true url2
    with Not_found -> ""
    in
    let get_params = Netencoding.Url.dest_url_encoded_parameters params_string 
    in
    let find_post_params = 
      if meth = Some(Http_header.GET) || meth = Some(Http_header.HEAD) 
      then return [] else 
        match http_frame.Stream_http_frame.content with
          None -> return []
        | Some body -> 
            let ct = (String.lowercase
                  (Http_header.get_headers_value
                     http_frame.Stream_http_frame.header "Content-Type")) in
            if ct = "application/x-www-form-urlencoded"
            then 
              catch
                (fun () ->
                  Ocsistream.string_of_stream body >>=
                  (fun r -> return
                      (Netencoding.Url.dest_url_encoded_parameters r)))
                (function
                    Ocsistream.String_too_large -> fail Input_is_too_large
                  | e -> fail e)
            else 
              match (Netstring_pcre.string_match 
                       (Netstring_pcre.regexp "multipart/form-data*")) ct 0
              with 
              | None -> fail Ocsigen_unsupported_media
              | _ ->
                  let bound = get_boundary ct in
                  let param_names = ref [] in
                  let create hs =
                    let cd = List.assoc "content-disposition" hs in
                    let st = try 
                      Some (find_field "filename" cd) 
                    with _ -> None in
                    let p_name = find_field "name" cd in
                    match st with 
                      None -> No_File (p_name, Buffer.create 1024)
                    | Some store -> 
                        let now = 
                          Printf.sprintf 
                            "%s-%f" store (Unix.gettimeofday ()) in
                        match ((Ocsiconfig.get_uploaddir ())) with
                          Some dname ->
                            let fname = dname^"/"^now in
                            let fd = Unix.openfile fname 
                                [Unix.O_CREAT;
                                 Unix.O_TRUNC;
                                 Unix.O_WRONLY;
                                 Unix.O_NONBLOCK] 0o666 in
                            (* Messages.debug "file opened"; *)
                            filenames := fname::!filenames;
                            param_names := 
                              !param_names@[(p_name, fname (* {tmp_filename=fname;
                                                              filesize=size;
                                                              original_filename=oname} *))];
                            A_File (Lwt_unix.Plain fd)
                        | None -> raise Ocsigen_upload_forbidden
                  in
                  let add where s =
                    match where with 
                      No_File (p_name, to_buf) -> 
                        Buffer.add_string to_buf s;
                        return ()
                    | A_File wh -> 
                        Lwt_unix.write wh s 0 (String.length s) >>= 
                        (fun r -> Lwt_unix.yield ())
                  in
                  let stop size  = function 
                      No_File (p_name, to_buf) -> 
                        return 
                          (param_names := !param_names @
                            [(p_name, Buffer.contents to_buf)])
                            (* � la fin ? *)
                    | A_File wh -> (match wh with 
                        Lwt_unix.Plain fdscr -> 
                          (* Messages.debug "closing file"; *)
                          Unix.close fdscr
                      | _ -> ());
                        return ()
                  in
                  Multipart.scan_multipart_body_from_stream 
                    body bound create add stop >>=
                  (fun () -> return !param_names)

(* AEFF *)              (*        IN-MEMORY STOCKAGE *)
              (* let bdlist = Mimestring.scan_multipart_body_and_decode s 0 
               * (String.length s) bound in
               * Messages.debug (string_of_int (List.length bdlist));
               * let simplify (hs,b) = 
               * ((find_field "name" 
               * (List.assoc "content-disposition" hs)),b) in
               * List.iter (fun (hs,b) -> 
               * List.iter (fun (h,v) -> Messages.debug (h^"=="^v)) hs) bdlist;
               * List.map simplify bdlist *)
    in
    find_post_params >>= (fun post_params ->
      let internal_state,post_params2 = 
        try (Some (int_of_string (List.assoc state_param_name post_params)),
             List.remove_assoc state_param_name post_params)
        with Not_found -> (None, post_params)
      in
      let internal_state2,get_params2 = 
        try 
          match internal_state with
            None ->
              (Some (int_of_string (List.assoc state_param_name get_params)),
               List.remove_assoc state_param_name get_params)
          | _ -> (internal_state, get_params)
        with Not_found -> (internal_state, get_params)
      in
      let action_info, post_params3 =
        try
          let action_name, pp = 
            ((List.assoc (action_prefix^action_name) post_params2),
             (List.remove_assoc (action_prefix^action_name) post_params2)) in
          let reload,pp2 =
            try
              ignore (List.assoc (action_prefix^action_reload) pp);
              (true, (List.remove_assoc (action_prefix^action_reload) pp))
            with Not_found -> false, pp in
          let ap,pp3 = pp2,[]
(*          List.partition 
   (fun (a,b) -> 
   ((String.sub a 0 action_param_prefix_end)= 
   full_action_param_prefix)) pp2 *) in
          (Some (action_name, reload, ap), pp3)
        with Not_found -> None, post_params2 in
      let useragent = try (Http_header.get_headers_value
                             http_frame.Stream_http_frame.header "user-agent")
      with _ -> ""
      in
      let ifmodifiedsince = try 
        Some (Netdate.parse_epoch 
                (Http_header.get_headers_value
                   http_frame.Stream_http_frame.header "if-modified-since"))
      with _ -> None
      in return
        (((path,   (* the url path (string list) *)
           params,
           internal_state2,
             ((Ocsimisc.remove_slash (Neturl.url_path url2)), 
              host,
              get_params2,
              post_params3,
              useragent)),
          action_info,
          ifmodifiedsince))))

    (fun e ->
      Messages.debug ("Exn during get_frame_infos : "^
                      (Printexc.to_string e));
      fail (Ocsigen_Request_interrupted e) (* ? *))
    

let rec getcookie s =
  let rec firstnonspace s i = 
    if s.[i] = ' ' then firstnonspace s (i+1) else i in
  let longueur = String.length s in
  let pointvirgule = try 
    String.index s ';'
  with Not_found -> String.length s in
  let egal = String.index s '=' in
  let first = firstnonspace s 0 in
  let nom = (String.sub s first (egal-first)) in
  if nom = cookiename 
  then String.sub s (egal+1) (pointvirgule-egal-1)
  else getcookie (String.sub s (pointvirgule+1) (longueur-pointvirgule-1))
(* On peut am�liorer �a *)

let remove_cookie_str = "; expires=Wednesday, 09-Nov-99 23:12:40 GMT"

let find_keepalive http_header =
  try
    let kah = String.lowercase 
        (Http_header.get_headers_value http_header "Connection") 
    in
    if kah = "keep-alive" 
    then true 
    else false (* should be "close" *)
  with _ ->
    (* if prot.[(String.index prot '/')+3] = '1' *)
    if (Http_header.get_proto http_header) = "HTTP/1.1"
    then true
    else false







let service wait_end_request waiter http_frame port sockaddr 
    xhtml_sender empty_sender inputchan () =
  (* waiter is here for pipelining: we must wait before sending the page,
     because the previous one may not be sent *)
  let head = ((Http_header.get_method http_frame.Stream_http_frame.header) 
                    = Some (Http_header.HEAD)) in
  let ka = find_keepalive http_frame.Stream_http_frame.header in
  Messages.debug ("Keep-Alive:"^(string_of_bool ka));
  Messages.debug("HEAD:"^(string_of_bool head));

  let remove_files = 
    let rec aux = function
        (* We remove all the files created by the request 
           (files sent by the client) *)
        [] -> ()
      | a::l -> 
          (try Unix.unlink a 
          with e -> Messages.warning ("Error while removing file "^a^
                                      ": "^(Printexc.to_string e))); 
          aux l
    in function
        [] -> ()
      | l -> Messages.debug "Removing files"; 
          aux l
  in


  let serv () =  

    let filenames = ref [] (* All the files sent by the request *) in

    catch (fun () ->
      
      let cookie = 
        try 
          Some (getcookie (Http_header.get_headers_value 
                             http_frame.Stream_http_frame.header "Cookie"))
        with _ -> None
      in

      (* *** First of all, we read all the request
         (that will possibly create files) *)
      get_frame_infos http_frame filenames >>=
      
      (* *** Now we generate the page and send it *)
      (fun (((stringpath,params,is,(path,host,gp,pp,ua)) as frame_info), action_info,ifmodifiedsince) -> 

        wakeup wait_end_request ();
        (* here we are sure that the request is terminated. 
           We can wait for another request *)
        
        catch
          (fun () ->
            
            (* log *)
            let ip = ip_of_sockaddr sockaddr in
            accesslog ("connection"^
                       (match host with 
                         None -> ""
                       | Some h -> (" for "^h))^
                       " from "^ip^" ("^ua^") : "^stringpath^params);
            (* end log *)
            
            
            match action_info with
              None ->
                let keep_alive = ka in

                (* page generation *)
                get_page frame_info port sockaddr cookie >>=
                (fun ((cookie2,send_page,sender,path), lastmodified,etag) ->

                    match lastmodified,ifmodifiedsince with
                      Some l, Some i when l<=i -> 
                        Messages.debug "Sending 304 Not modified ";
                        send_empty
                          waiter
                          ?last_modified:lastmodified
                          ?etag:etag
                          ~keep_alive:keep_alive
                          ~code:304 (* Not modified *)
                          ~head:head empty_sender

                    | _ ->
                        send_page waiter ~keep_alive:keep_alive
                          ?last_modified:lastmodified
                          ?cookie:(if cookie2 <> cookie then 
                            (if cookie2 = None 
                            then Some remove_cookie_str
                            else cookie2) 
                          else None)
                          ~path:path (* path pour le cookie *) ~head:head
                          (sender ~server_name:server_name inputchan))

            | Some (action_name, reload, action_params) ->

                (* action *)
                make_action 
                  action_name action_params frame_info sockaddr cookie
                  >>= (fun (cookie2,path) ->
                    let keep_alive = ka in
                    (if reload then
                      get_page frame_info port sockaddr cookie2 >>=
                      (fun ((cookie3,send_page,sender,path),
                            lastmodified,etag) ->
                        (send_page waiter ~keep_alive:keep_alive 
                           ?last_modified:lastmodified
                           ?cookie:(if cookie3 <> cookie then 
                             (if cookie3 = None 
                             then Some remove_cookie_str
                             else cookie3) 
                           else None)
                           ~path:path ~head:head
                           (sender ~server_name:server_name inputchan)))
                    else
                      (send_empty waiter ~keep_alive:keep_alive 
                         ?cookie:(if cookie2 <> cookie then 
                           (if cookie2 = None 
                           then Some remove_cookie_str
                           else cookie2) 
                         else None)
                         ~path:path
                         ~code:204 ~head:head
                         empty_sender))
                      )
          )
          
          
          (fun e -> (* Exceptions during page generation *)
            Messages.debug 
              ("~~~~ Exception during generation/sending: "^
               (Printexc.to_string e));
            catch
              (fun () ->
                match e with
                  (* EXCEPTIONS WHILE COMPUTING A PAGE *)
                  Ocsigen_404 -> 
                    Messages.debug "Sending 404 Not Found";
                    send_error 
                      waiter ~keep_alive:ka ~error_num:404 xhtml_sender
                | Ocsigen_sending_error exn -> fail exn
                | Ocsigen_Is_a_directory -> 
                    Messages.debug "Sending 301 Moved permanently";
                    send_empty
                      waiter
                      ~keep_alive:ka
                      ~location:(stringpath^"/"^params)
                      ~code:301 (* Moved permanently *)
                      ~head:head empty_sender
                | Pagesearch.Ocsigen_malformed_url
                | Neturl.Malformed_URL -> 
                    Messages.debug "Sending 400 (Malformed URL)";
                    send_error waiter ~keep_alive:ka
                      ~error_num:400 xhtml_sender (* Malformed URL *)
                | Unix.Unix_error (Unix.EACCES,_,_) ->
                    Messages.debug "Sending 303 Forbidden";
                    send_error waiter ~keep_alive:ka
                      ~error_num:403 xhtml_sender (* Forbidden *)
                | e ->
                    Messages.warning
                      ("Exn during page generation: "^
                       (Printexc.to_string e)^" (sending 500)"); 
                    Messages.debug "Sending 500";
                    send_error
                      waiter ~keep_alive:ka ~error_num:500 xhtml_sender)
              (fun e -> fail (Ocsigen_sending_error e))
            (* All generation exceptions have been handled here *)
          )) >>=

      (fun () -> return (remove_files !filenames)))
              
      (fun e -> 
        remove_files !filenames;
        match e with
          Ocsigen_sending_error _ -> fail e
        | _ -> handle_light_request_errors
              xhtml_sender sockaddr wait_end_request waiter e)

  in 

(*  let consume = function
        None -> return ()
      | Some body -> Ocsistream.consume body
  in *)


  (* body of service *)
  let meth = (Http_header.get_method http_frame.Stream_http_frame.header) in
  if ((meth <> Some (Http_header.GET)) && 
      (meth <> Some (Http_header.POST)) && 
      (meth <> Some(Http_header.HEAD)))
  then send_error waiter ~keep_alive:ka ~error_num:501 xhtml_sender
  else 
    catch

      (* new version: in case of error, we close the request *)
      (fun () ->
        (try
          return 
            (Int64.of_string 
               (Http_header.get_headers_value 
                  http_frame.Stream_http_frame.header 
                  "content-length"))
        with
          Not_found -> return Int64.zero
        | _ -> fail (Ocsigen_Request_interrupted Ocsigen_Bad_Request))
        >>=
            (fun cl ->
              if (Int64.compare cl Int64.zero) > 0 &&
                (meth = Some Http_header.GET || meth = Some Http_header.HEAD)
              then fail (Ocsigen_Request_interrupted Ocsigen_Bad_Request)
              else serv ()))


          (* old version: in case of error, 
             we consume all the stream and wait another request
             fun () ->
             (try
             return 
             (Int64.of_string 
             (Http_header.get_headers_value 
             http_frame.Stream_http_frame.header 
             "content-length"))
             with
             Not_found -> return Int64.zero
             | _ -> (consume http_frame.Stream_http_frame.content >>=
             (fun () ->
             wakeup wait_end_request ();
             fail Ocsigen_Bad_Request)))
             >>=
             (fun cl ->
             if (Int64.compare cl Int64.zero) > 0 &&
             (meth = Some Http_header.GET || meth = Some Http_header.HEAD)
             then consume http_frame.Stream_http_frame.content >>=
             (fun () ->
             wakeup wait_end_request ();
             send_error waiter ~keep_alive:ka ~error_num:501 xhtml_sender)
             else serv ()) *)

      (function
        | Ocsigen_Request_interrupted _ as e -> fail e
        | Ocsigen_sending_error e ->
            Messages.debug ("Exn while sending: "^
                            (Printexc.to_string e)); 
            fail e
        | e -> Messages.debug ("Exn during service: "^
                               (Printexc.to_string e)); 
            fail e)







let load_modules modules_list =
  let rec aux = function
      [] -> ()
    | (Cmo s)::l -> Dynlink.loadfile s; aux l
    | (Host (host,sites))::l -> 
        load_ocsigen_module host sites; 
        aux l
  in
  Dynlink.init ();
  Dynlink.allow_unsafe_modules true;
  aux modules_list;
  load_ocsigen_module
    [[Wildcard],None] [[],([(* no cmo *)], (get_default_static_dir ()))]
    (* for default static dir *)


let handle_broken_pipe_exn sockaddr in_ch exn = 
  (* EXCEPTIONS WHILE REQUEST OR SENDING WHEN WE CANNOT ANSWER *)
  let ip = ip_of_sockaddr sockaddr in
  (* Do we close the connection here? Probably not.
     Either the error is during a request, and the connection is already 
     closed, or during the answer, but the thread waiting for requests will
     close the connections (for example by timeout of keepalive).
     If we close here, we will always close twice. 
     But are we sure that it is closed for all possible exceptions?
     Especially I don't think so for Ssl.Read_error
     Better try to close.
   *)
  (try
    Lwt_unix.lingering_close in_ch
  with _ -> ());
  match exn with
    Connection_reset_by_peer -> 
      Messages.debug "Connection closed by client";
      return ()
  | Unix.Unix_error (e,func,param) ->
      warning ("While talking to "^ip^": "^(Unix.error_message e)^
               " in function "^func^" ("^param^").");
      return ()
  | Ssl.Write_error(Ssl.Error_ssl) -> 
      errlog ("While talking to "^ip^": Ssl broken pipe.");
      return ()
  | exn -> 
      warning ("While talking to "^ip^": Uncaught exception - "
              ^(Printexc.to_string exn)^".");
      return ()




(** Thread waiting for events on a the listening port *)
let listen ssl port wait_end_init =
  
  let listen_connexion receiver in_ch sockaddr 
      xhtml_sender empty_sender =
    
    (* (With pipeline) *)

    let handle_severe_errors = function
        (* Serious error (we cannot answer to the request)
           Probably the pipe is broken.
           We awake all the waiting threads in cascade
           with an exception.
         *)
(*        Stop_sending -> 
          wakeup_exn waiter Stop_sending;
          return () *)
        (* Timeout errors: We close and do nothing *)
      | Ocsigen_Timeout -> 
          let ip = ip_of_sockaddr sockaddr in
          warning ("While talking to "^ip^": Timeout");
          Lwt_unix.lingering_close in_ch;
          return ()
      | Http_com.Ocsigen_KeepaliveTimeout -> 
          Lwt_unix.lingering_close in_ch;
          return ()
      | Ocsigen_Request_interrupted e -> 
          (* We decide to interrupt the request 
             (for ex if it is too long) *)
          (try
            Lwt_unix.lingering_close in_ch
          with _ -> ());                   
          handle_broken_pipe_exn sockaddr in_ch e (* >>=
          (fun () -> 
            wakeup_exn waiter Stop_sending;
            return ()) *)
      | e ->
          handle_broken_pipe_exn sockaddr in_ch e (* >>=
          (fun () -> 
            wakeup_exn waiter Stop_sending;
            return ())) *)
    in  

    let handle_request_errors wait_end_request waiter exn =
      catch
        (fun () -> 
          handle_light_request_errors 
            xhtml_sender sockaddr wait_end_request waiter exn)
        (fun e -> handle_severe_errors exn)
    in

    let rec handle_request waiter http_frame =

     let test_end_request_awoken wait_end_request =
        try
          wakeup wait_end_request ();
          Messages.debug
            "wait_end_request has not been awoken! \
            (should not succeed ...)"
        with _ -> ()
      in

      let keep_alive = find_keepalive http_frame.Stream_http_frame.header in

      if keep_alive 
      then begin
        Messages.debug "KEEP ALIVE (pipelined)";
        let waiter2 = wait () in
        (* The following request must wait the end of this one
           before being answered *)
        (* waiter is awoken when the previous request has been answered *)
        let wait_end_request = wait () in
        (* The following request must wait the end of this one.
           (It may not be finished, for example if we are downloading files) *)
        (* wait_end_request is awoken when we are sure it is terminated *)
        ignore_result 
          (catch
             (fun () ->
               service wait_end_request waiter http_frame port sockaddr 
                 xhtml_sender empty_sender in_ch () >>=
               (fun () ->
                 test_end_request_awoken wait_end_request;
                 wakeup waiter2 (); 
                 return ()))
             handle_severe_errors);
        
        catch
          (fun () ->
            wait_end_request >>=
            (fun () -> 
              Messages.debug "Waiting for new request (pipeline)";
              Stream_receiver.get_http_frame waiter2
                receiver ~doing_keep_alive:true () >>=
              (handle_request waiter2)))
          (handle_request_errors wait_end_request waiter2)
      end

      else begin (* No keep-alive => no pipeline *)
        catch
          (fun () ->
            service (wait ()) waiter http_frame port sockaddr
              xhtml_sender empty_sender in_ch () >>=
            (fun () ->
              (Lwt_unix.lingering_close in_ch; 
               return ())))
          (fun e ->
            Lwt_unix.lingering_close in_ch; fail e)
      end

    in (* body of listen_connexion *)
    catch
      (fun () ->
        catch
          (fun () ->
            Stream_receiver.get_http_frame (return ())
              receiver ~doing_keep_alive:false () >>=
            handle_request (return ()))
          (handle_request_errors now now))
      (handle_broken_pipe_exn sockaddr in_ch)

        (* Without pipeline:
        Stream_receiver.get_http_frame receiver ~doing_keep_alive () >>=
        (fun http_frame ->
          (service http_frame sockaddr 
             xhtml_sender empty_sender in_ch ())
            >>= (fun keep_alive -> 
              if keep_alive then begin
                Messages.debug "KEEP ALIVE";
                listen_connexion_aux ~doing_keep_alive:true
                  (* Pour laisser la connexion ouverte, je relance *)
              end
              else (Lwt_unix.lingering_close in_ch; 
                    return ())))
        *)
        
  in 
  let wait_connexion port socket =
    let handle_connection (inputchan, sockaddr) =
      debug "\n__________________NEW CONNECTION__________________________";
      catch
        (fun () -> 
          let xhtml_sender = 
            Sender_helpers.create_xhtml_sender
              ~server_name:server_name inputchan in
          (* let file_sender =
            create_file_sender ~server_name:server_name inputchan
          in *)
          let empty_sender =
            create_empty_sender ~server_name:server_name inputchan
          in
          listen_connexion 
            (Stream_receiver.create inputchan)
            inputchan sockaddr xhtml_sender
            empty_sender)
        (handle_broken_pipe_exn sockaddr inputchan)
    in

    let rec wait_connexion_rec () =

      let rec do_accept () = 
        Lwt_unix.accept (Lwt_unix.Plain socket) >>= 
        (fun (s, sa) -> 
          if ssl
          then begin
                let s_unix = 
              match s with
                Lwt_unix.Plain fd -> fd 
                  | _ -> raise Ssl_Exception (* impossible *) 
            in
                catch 
                  (fun () -> 
                ((Lwt_unix.accept
                    (Lwt_unix.Encrypted 
                       (s_unix, 
                        Ssl.embed_socket s_unix !sslctx))) >>=
                 (fun (ss, ssa) -> Lwt.return (ss, sa))))
                  (function
                      Ssl.Accept_error e -> 
                        Messages.debug "Accept_error"; do_accept ()
                    | e -> warning ("Exn in do_accept : "^
                                    (Printexc.to_string e)); do_accept ())
          end 
          else Lwt.return (s, sa))
      in

      (do_accept ()) >>= 
      (fun c ->
        incr_connected ();
        catch

          (fun () ->
            if (get_number_of_connected ()) <
              (get_max_number_of_connections ()) then
              ignore_result (wait_connexion_rec ())
            else warning ("Max simultaneous connections ("^
                          (string_of_int (get_max_number_of_connections ()))^
                          ") reached.");
            handle_connection c)

          (fun e -> 
            decr_connected ();
            fail e
          )

      ) >>= 

      (fun () -> 
        decr_connected (); 
        if (get_number_of_connected ()) = 
          (get_max_number_of_connections ()) - 1
        then begin
          warning "Ok releasing one connection";
          wait_connexion_rec ()
        end
        else return ())

    in wait_connexion_rec ()

  in (* body of listen *)
  (new_socket () >>= 
   (fun listening_socket ->
     catch

       (fun () ->
         Unix.setsockopt listening_socket Unix.SO_REUSEADDR true;
         Unix.bind listening_socket (local_addr port);
         Unix.listen listening_socket 1;
         
         wait_end_init >>=
         (fun () -> wait_connexion port listening_socket))

       (function
         | Unix.Unix_error (Unix.EACCES,"bind",s2) ->
             errlog ("Fatal - You are not allowed to use port "^
                     (string_of_int (port))^".");
             exit 7
         | Unix.Unix_error (Unix.EADDRINUSE,"bind",s2) ->
             errlog ("Fatal - The port "^
                     (string_of_int port)^
                     " is already in use.");
             exit 8
         | exn ->
             errlog ("Fatal - Uncaught exception: "^(Printexc.to_string exn));
             exit 100
       )
   ))




let _ = try

  parse_config ();

  Messages.debug ("number_of_servers: "^ 
                  (string_of_int !Ocsiconfig.number_of_servers));

  let ask_for_passwd h _ =
    print_string "Please enter the password for the HTTPS server listening \
      on port(s) ";
      print_string
      (match Ocsiconfig.get_sslports_n h with
        [] -> assert false
      | a::l -> List.fold_left
            (fun deb i -> deb^", "^(string_of_int i)) (string_of_int a) l);
    print_string ": ";
    let old_term= Unix.tcgetattr Unix.stdin in
    let old_echo = old_term.Unix.c_echo in
    old_term.Unix.c_echo <- false;
    Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_term;
    try
      let r = read_line () in
      print_newline ();
      old_term.Unix.c_echo <- old_echo;
      Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_term;
      r
    with exn ->
      old_term.Unix.c_echo <- old_echo;
      Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_term;
      raise exn
  in

  let run s =
    Ocsiconfig.sconf := s;
    Messages.open_files ();
    Ocsiconfig.cfgs := [];
    (* Gc.full_major (); *)

    if (get_maxthreads ()) < (get_minthreads ())
    then 
      raise (Config_file_error "maxthreads should be greater than minthreads");

    Lwt_unix.run 
      (ignore (Preemptive.init 
                 (Ocsiconfig.get_minthreads ()) 
                 (Ocsiconfig.get_maxthreads ()));

       (* Je suis fou
          let rec f () = 
          (*   print_string "-"; *)
          Lwt_unix.yield () >>= f
          in f(); *)


       let wait_end_init = wait () in
       (* Listening on all ports: *)
       List.iter 
         (fun i -> 
           ignore (listen false i wait_end_init)) (Ocsiconfig.get_ports ());
       List.iter 
         (fun i ->
           ignore (listen true i wait_end_init)) (Ocsiconfig.get_sslports ());

       (* I change the user for the process *)
       (try
         Unix.setgid (Unix.getgrnam (Ocsiconfig.get_group ())).Unix.gr_gid;
         Unix.setuid (Unix.getpwnam (Ocsiconfig.get_user ())).Unix.pw_uid;
       with e -> errlog ("Error: Wrong user or group"); raise e);
       
       (* Now I can load the modules *)
       load_modules (Ocsiconfig.get_modules ());

       (* A thread that kills old connections every n seconds *)
       ignore (Http_com.Timeout.start_timeout_killer ());
       
       end_initialisation ();

       wakeup wait_end_init ();
       
       warning "Ocsigen has been launched (initialisations ok)";

       wait ()
      )
  in

  let set_passwd_if_needed h =
    if get_sslports_n h <> []
    then
      match (get_certificate h), (get_key h) with
        None, None -> ()
      | None, _ -> raise (Ocsiconfig.Config_file_error
                            "SSL certificate is missing")
      | _, None -> raise (Ocsiconfig.Config_file_error 
                            "SSL key is missing")
      | (Some c), (Some k) -> 
          Ssl.set_password_callback !sslctx (ask_for_passwd h);
          Ssl.use_certificate !sslctx c k
  in

  let write_pid pid =
    match Ocsiconfig.get_pidfile () with
      None -> ()
    | Some p ->
        let spid = (string_of_int pid)^"\n" in
        let len = String.length spid in
        let f =
          Unix.openfile
            p
            [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o640 in
        ignore (Unix.write f spid 0 len);
        Unix.close f
  in

  let rec launch = function
      [] -> () 
    | h::t -> 
        set_passwd_if_needed h;
        let pid = Unix.fork () in
        if pid = 0
        then run h
        else begin
          print_endline ("Process "^(string_of_int pid)^" detached");
          write_pid pid;
          launch t
        end

  in

  if (not (get_daemon ())) &&
    !Ocsiconfig.number_of_servers = 1 
  then
    let cf = List.hd !Ocsiconfig.cfgs in
    (set_passwd_if_needed cf;
     write_pid (Unix.getpid ());
     run cf)
  else launch !Ocsiconfig.cfgs

with
  Ocsigen_duplicate_registering s -> 
    errlog ("Fatal - Duplicate registering of url \""^s^
            "\". Please correct the module.");
    exit 1
| Ocsigen_there_are_unregistered_services s ->
    errlog ("Fatal - Some public url have not been registered. \
              Please correct your modules. (ex: "^s^")");
    exit 2
| Ocsigen_service_or_action_created_outside_site_loading ->
    errlog ("Fatal - An action or a service is created outside \
              site loading phase");
    exit 3
| Ocsigen_page_erasing s ->
    errlog ("Fatal - You cannot create a page or directory here: "^s^
            ". Please correct your modules.");
    exit 4
| Ocsigen_register_for_session_outside_session ->
    errlog ("Fatal - Register session during initialisation forbidden.");
    exit 5
| Dynlink.Error e -> 
    errlog ("Fatal - Dynamic linking error: "^(Dynlink.error_message e));
    exit 6
| Unix.Unix_error (e,s1,s2) ->
    errlog ("Fatal - "^(Unix.error_message e)^" in: "^s1^" "^s2);
    exit 9
| Ssl.Private_key_error ->
    errlog ("Fatal - bad password");
    exit 10
| exn -> 
    errlog ("Fatal - Uncaught exception: "^(Printexc.to_string exn));
    exit 100


